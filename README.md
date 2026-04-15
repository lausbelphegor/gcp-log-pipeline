# gcp-log-pipeline

A log ingestion and observability pipeline on GCP. Structured application events flow from a Python producer through Kafka, get indexed into Elasticsearch by a Python consumer, and are visualized in Kibana.

Built to demonstrate platform engineering skills: cloud infrastructure provisioning, configuration management, stream processing, and search/observability tooling.

```
[Python producer]  →  [Kafka]  →  [Consumer]  →  [Elasticsearch]  →  [Kibana]
   local machine       GCE           GCE              GCE               browser
```

---

## Stack

| Layer                    | Technology                                     |
| ------------------------ | ---------------------------------------------- |
| Cloud                    | GCP (GCE, VPC, GCS)                            |
| Infrastructure as code   | Terraform                                      |
| Configuration management | Ansible                                        |
| Message broker           | Apache Kafka (Confluent image, Zookeeper mode) |
| Search / storage         | Elasticsearch 8.13                             |
| Visualization            | Kibana 8.13                                    |
| Runtime                  | Docker Compose                                 |
| Application              | Python 3.12                                    |

---

## Architecture

Two GCE instances in a custom VPC (`10.0.1.0/24`):

**kafka-instance** (`e2-medium`, `europe-west1-b`)

- Zookeeper on port 2181 (internal only)
- Kafka broker on port 29092 (internal) and 9092 (external, your IP only)

**elk-instance** (`e2-medium`, `europe-west1-b`)

- Elasticsearch on port 9200 (internal only)
- Kibana on port 5601 (your IP only)
- Python consumer (Docker container, built on host)

The producer runs locally. It connects to Kafka on port `9092` via the Kafka instance's public IP. The consumer runs on the ELK host and connects to Kafka on port `9092` via the Kafka instance's private IP, keeping that traffic inside the VPC. Kafka is configured with two listeners — `EXTERNAL` advertised on the public IP for the producer, `INTERNAL` on the Docker network for intra-host broker communication — to handle both paths simultaneously.

Terraform state is stored remotely in GCS. Ansible inventory is generated from Terraform outputs — there are no manually maintained IP addresses anywhere in the repo.

### Why Kafka instead of writing directly to Elasticsearch

Kafka decouples producers from the indexing pipeline. If Elasticsearch is slow or restarting, the producer keeps writing without dropping events. The consumer reads at its own pace and can replay from any offset. Direct writes to ES mean a slow index creates back-pressure or data loss on the application side.

---

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) — authenticated (`gcloud auth login`)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) >= 2.14
- Python 3.12
- An SSH key at `~/.ssh/id_ed25519` (or set `ssh_pub_key_path` in `terraform.tfvars`)
- A GCP project with billing enabled

---

## Setup

### 1. Bootstrap GCP (once)

```bash
gcloud auth login
gcloud config set project gcp-log-pipeline

gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com

# Create Terraform state bucket
gcloud storage buckets create gs://gcp-log-pipeline-tfstate-lausbelphegor \
  --location=europe-west1 \
  --uniform-bucket-level-access

# Create Terraform service account with least-privilege roles
gcloud iam service-accounts create terraform --display-name="Terraform"

for role in roles/compute.admin roles/iam.serviceAccountUser \
            roles/storage.admin roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding gcp-log-pipeline \
    --member="serviceAccount:terraform@gcp-log-pipeline.iam.gserviceaccount.com" \
    --role="$role"
done

gcloud iam service-accounts keys create ./terraform/credentials.json \
  --iam-account=terraform@gcp-log-pipeline.iam.gserviceaccount.com
```

### 2. Configure Terraform

Create `terraform/terraform.tfvars` (this file is gitignored):

```hcl
project_id = "gcp-log-pipeline"
your_ip    = "YOUR.PUBLIC.IP.HERE/32"  # curl -s ifconfig.me
```

### 3. Provision infrastructure

```bash
make init
make apply
```

Two GCE instances will be created. Outputs will show their public and private IPs.

### 4. Deploy services

```bash
make deploy
```

This runs the full Ansible playbook: installs Docker on both hosts, deploys Kafka + Zookeeper on the kafka instance, creates the `app-logs` topic, syncs and builds the consumer, then deploys Elasticsearch + Kibana + consumer on the ELK instance.

### 5. Run the producer

```bash
make produce
```

The producer reads the Kafka public IP from Terraform outputs automatically. It generates fake structured log events and publishes them at ~2–10 events/second.

### 6. Open Kibana

```bash
terraform -chdir=terraform output elk_public_ip
# Open http://<elk_public_ip>:5601 — allow ~90 seconds for Kibana to start
```

Create a Data View: `Stack Management → Data Views → Create data view`, name `app-logs`, index pattern `app-logs`, time field `timestamp`.

---

## Verification

After a full deploy, verify in this order:

```bash
# Kafka topic exists
make inventory
ansible kafka -i ansible/inventory.ini --become \
  -a "docker exec kafka-kafka-1 kafka-topics --bootstrap-server localhost:9092 --list"

# Elasticsearch healthy (9200 is internal-only — check via SSH)
ansible elk -i ansible/inventory.ini --become \
  -a "docker exec elk-elasticsearch-1 curl -s localhost:9200/_cluster/health"

# Consumer is running and indexing
ansible elk -i ansible/inventory.ini --become \
  -a "docker logs elk-consumer-1 --tail 20"
```

---

## Common operations

```bash
make init           # terraform init
make plan           # terraform plan
make apply          # create / update infrastructure
make destroy        # destroy all GCP resources — always run when done
make inventory      # regenerate ansible/inventory.ini from terraform outputs
make deploy         # full ansible deploy (all roles)
make deploy-kafka   # kafka role only
make deploy-elk     # elk role only (also rebuilds consumer image)
make produce        # run producer locally
```

Staged Ansible deploy for debugging:

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml --tags docker
ansible-playbook -i inventory.ini playbook.yml --tags kafka
ansible-playbook -i inventory.ini playbook.yml --tags elk
```

---

## Event schema

The producer generates JSON events with this shape:

```json
{
  "timestamp": "2024-01-15T10:30:00.000000+00:00",
  "service": "payment-service",
  "level": "ERROR",
  "message": "Payment failed",
  "response_time_ms": null,
  "request_id": "req-42301"
}
```

Services: `api-gateway`, `auth-service`, `payment-service`, `notification-service`  
Levels: `INFO` (~60%), `WARN` (~20%), `ERROR` (~20%)  
`response_time_ms` is set on `INFO` events only.

---

## Cost

Two `e2-medium` instances in `europe-west1` cost approximately **$0.07/hour** combined. Always run `make destroy` when you are done.

---

## Design decisions

This is a demo-tier deployment, not production-ready infrastructure. See [DECISIONS.md](./DECISIONS.md) for a full breakdown of intentional tradeoffs. The short version:

- Single-broker Kafka and single-node Elasticsearch — no HA
- Elasticsearch security disabled (`xpack.security=false`) — ES is not publicly exposed; firewall is the boundary
- Docker Compose instead of GKE — operational overhead not justified at this scale
- Public IPs on both VMs — SSH convenience; a bastion or IAP tunnel would be the production choice
- Zookeeper-based Kafka — KRaft would be the choice today for new deployments
- 1 GB ES heap — compromise to fit on `e2-medium`; size to 50% of available RAM in production

---

## Troubleshooting

| Symptom                             | Likely cause                                | Fix                                                                           |
| ----------------------------------- | ------------------------------------------- | ----------------------------------------------------------------------------- |
| `NoBrokersAvailable` from producer  | Kafka firewall or wrong advertised listener | Check `allow-kafka-external` firewall rule; verify Kafka public IP in compose |
| ES container keeps restarting       | `vm.max_map_count` not set                  | `ssh debian@ELK_IP "sysctl vm.max_map_count"` should be 262144                |
| Kibana unreachable on :5601         | Still starting up                           | Wait 90 seconds; check `docker logs elk-kibana-1`                             |
| Consumer not indexing               | ES readiness timeout or Kafka unreachable   | Check consumer logs; verify Kafka private IP in compose env                   |
| `docker compose up --build` fails   | Consumer source not synced                  | Re-run `make deploy-elk` — the sync step precedes the build                   |
| Firewall blocks you after IP change | Dynamic home IP                             | Update `your_ip` in `terraform.tfvars`, run `make apply`                      |
