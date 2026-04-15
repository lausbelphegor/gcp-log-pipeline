# DECISIONS.md

Design decisions for `gcp-log-pipeline`. Read this before changing something that looks like an oversight — most of the apparent shortcuts are intentional, and the reasoning is here.

Each decision has a status:

- **accepted** — correct choice for this scope, keep it
- **shortcut** — known tradeoff, acceptable for demo, documented for awareness
- **revisit** — the right direction for a v2 if the project graduates from demo

---

## Architecture

### Two VMs instead of one

**Status:** accepted

Kafka and the ELK stack run on separate instances. ES alone wants 1–2 GB heap; Kafka + Zookeeper add another ~1 GB. A single `e2-medium` (4 GB) would be too tight to run all four containers without OOM kills under any real load. Separate instances also produce a cleaner architecture story: the transport layer is distinct from the storage and visualization layer.

### Docker Compose instead of Kubernetes

**Status:** shortcut

Compose is the right tool here. GKE adds IAM complexity, node pool sizing, persistent volume configuration, and networking overhead that is not justified for four containers across two hosts. The purpose of the project is to demonstrate the pipeline, not Kubernetes operations. If this became a real service, the Compose files map cleanly to Deployments and Services.

### Local producer instead of a third VM

**Status:** accepted

Running the producer locally keeps the cost at two instances instead of three, gives direct control over message rate during demos, and exercises the Kafka external listener — which is a more interesting configuration than a purely internal setup. The firewall rule `allow-kafka-external` exposes port `9092` to your IP only.

### Kafka with Zookeeper instead of KRaft

**Status:** shortcut

KRaft (ZooKeeper-less Kafka) is the current direction and would be the choice for a new deployment today. Zookeeper mode was used here because the Confluent documentation and examples for it are more mature and the dual-listener configuration is better documented. The operational difference is negligible at single-broker scale.

### Single Kafka broker, single-node Elasticsearch

**Status:** shortcut

No fault tolerance anywhere in the pipeline. One host failure takes everything down. This is a demo, not a production service. Both systems are configured explicitly for single-node operation: `KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1` and `discovery.type=single-node`. These settings would need to change before adding nodes — they are not just cosmetic.

---

## Networking

### Dual Kafka listeners

**Status:** accepted

The broker runs two listeners:

- `EXTERNAL://0.0.0.0:9092` — advertised as `<kafka_public_ip>:9092` — used by the local producer over the public internet
- `INTERNAL://0.0.0.0:29092` — advertised as `kafka:29092` — used within the Kafka host's Docker network, for example by tooling containers running alongside the broker

The consumer on the ELK host connects to Kafka on port `9092` via the Kafka instance's **private IP**, keeping that traffic inside the VPC. This is not the same path as the `INTERNAL` listener, which only operates within the Kafka container network.

Both `KAFKA_LISTENERS` and `KAFKA_ADVERTISED_LISTENERS` are set explicitly. Removing or merging them breaks either the external producer path or the internal broker path.

### Public IPs on both VMs

**Status:** shortcut

Both instances have public IPs for SSH convenience. In a stronger posture, instances would have private IPs only and access would go through Cloud IAP (`gcloud compute ssh --tunnel-through-iap`) or a bastion host. The firewall restricts SSH and Kibana to your IP only, so the exposure is bounded, but the public IP surface exists.

### Elasticsearch not publicly exposed

**Status:** accepted

Port `9200` has no firewall rule permitting access from outside the VPC. ES has security disabled (`xpack.security=false`), so any host that can reach `9200` has full unauthenticated access. The firewall is the only boundary. Verification of ES health must go through `docker exec` over SSH, not a direct curl from your local machine.

### Firewall tied to `var.your_ip`

**Status:** accepted, with known fragility

All external-facing rules (`allow-ssh`, `allow-kafka-external`, `allow-kibana`) source from `var.your_ip`. Dynamic home IPs will break access when they rotate. Fix: update `terraform.tfvars` and run `terraform apply` — only firewall rules are updated, no instances are touched.

---

## Infrastructure as code

### GCS remote state

**Status:** accepted

State is stored in `gs://gcp-log-pipeline-tfstate-lausbelphegor/log-pipeline/state`. This is the correct choice for this project and a good default for GCP Terraform work generally. Committing local state (as in the proxy project) leaks account IDs, resource IDs, and public IPs into version history. The bucket must be created before `terraform init` — there is a bootstrap script for this in the README.

### Least-privilege IAM for Terraform SA

**Status:** accepted

The Terraform service account has four roles: `compute.admin`, `iam.serviceAccountUser`, `storage.admin`, `serviceusage.serviceUsageConsumer`. It does not have `roles/editor`. These four roles cover everything this Terraform config currently does. If a new resource type is added, add the required role explicitly rather than escalating to `roles/editor`.

### Static JSON key for Terraform credentials

**Status:** shortcut

A service account JSON key at `terraform/credentials.json` is the fastest path for local development. It is gitignored. The production alternative is Application Default Credentials or Workload Identity Federation (for CI/CD), neither of which requires a key file on disk. The key has no expiry — rotate it if the repo becomes shared or if the file is ever accidentally exposed.

### Output names are a stable interface

**Status:** accepted

`terraform/outputs.tf` exports `kafka_public_ip`, `kafka_private_ip`, `elk_public_ip`, `elk_private_ip`. These names are consumed by `ansible/gen_inventory.sh` by exact string match. Renaming them requires updating the shell script. They are documented as an interface, not implementation details.

---

## Configuration management

### Ansible inventory generated from Terraform outputs

**Status:** accepted

`ansible/inventory.ini` is always generated by `gen_inventory.sh`, never hand-maintained. This means there are no manually managed IPs anywhere in the repo. The generated file is gitignored. Always run `make inventory` after `terraform apply` before running any Ansible commands — IPs change if instances are destroyed and recreated.

### Consumer source synced to ELK host at deploy time

**Status:** accepted

The consumer Docker image is built on the ELK host from source synced by Ansible (`synchronize` module). There is no container registry. This keeps the setup self-contained — no registry credentials, no push/pull step, no registry dependency. The tradeoff is that `make deploy-elk` must be re-run after any consumer code change to rebuild the image.

### Tags at play level, not task level

**Status:** accepted

`--tags kafka` in Ansible runs the entire kafka play, not individual tasks within it. This is the correct granularity for this playbook — the roles are small enough that task-level tagging would add noise without benefit. Do not add task-level tags unless a specific use case requires it.

---

## Application

### Explicit Elasticsearch index mapping

**Status:** accepted

The consumer creates the `app-logs` index with an explicit mapping on first run rather than relying on ES dynamic mapping. This prevents `service` and `level` from being mapped as `text` (which would make them unsearchable by exact value and break Kibana aggregations). Dynamic mapping is fine for exploration but unreliable for a dashboard that depends on field types being correct.

### Consumer owns index creation

**Status:** accepted

The consumer checks for the index on startup and creates it if absent. This keeps ES schema management co-located with the code that understands the schema. The alternative — creating the index in Ansible or Terraform — would split the mapping definition away from the consumer that uses it.

### ES readiness retry loop in consumer

**Status:** accepted

The consumer retries `es.info()` up to 15 times with 6-second delays before failing. `depends_on: elasticsearch` in Docker Compose only waits for the ES container to start, not for ES to be ready to accept requests. ES takes 20–40 seconds to initialize. Without the retry loop, the consumer crashes on startup and Compose's `restart: unless-stopped` recovers it, but the log output looks like a failure. The retry loop makes the startup clean.

### Single-document indexing, not bulk

**Status:** accepted

Events are indexed one at a time with `es.index()`. At ~2–10 events/second, bulk indexing would add complexity with no measurable benefit. If throughput increases significantly, switch to `elasticsearch.helpers.bulk()` with a buffer of ~500 documents.

### Producer throughput capped at ~10 events/second

**Status:** accepted

`time.sleep(random.uniform(0.1, 0.5))` between events is intentional. ES on `e2-medium` with 1 GB heap under sustained high ingest will fall behind and eventually OOM. The sleep keeps the demo stable. The rate can be changed via the sleep values in `producer.py` if needed, but do not remove it entirely.

---

## Security posture

This project's security model is: keep everything off the public internet except the minimum required for the demo, and let the firewall do the work. That is appropriate for a single-user demo repo. It is not appropriate for a shared or production deployment.

Specific accepted risks:

- Elasticsearch has no authentication. Any host that can reach port `9200` has full access. The firewall has no rule permitting external access to `9200`.
- Kafka has no TLS or SASL. Traffic between the ELK host and the Kafka instance is plaintext inside the VPC.
- The Terraform SA key is a long-lived credential. It is gitignored and should never be committed or shared.
- Kibana has no authentication. Port `5601` is open to `var.your_ip` only.

None of these are acceptable in a production or shared environment. They are documented here so that a reader knows they are known, not overlooked.
