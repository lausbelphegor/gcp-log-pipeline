# gcp-log-pipeline — build plan

## Project identifiers

- GCP project ID: `gcp-log-pipeline`
- Terraform state bucket: `gcp-log-pipeline-tfstate-lausbelphegor`
- Region/zone: `europe-west1` / `europe-west1-b`
- Kafka instance: `kafka-instance` · e2-medium · 20 GB
- ELK instance: `elk-instance` · e2-medium · 30 GB

---

## Repository structure

```
gcp-log-pipeline/
├── terraform/
│   ├── backend.tf
│   ├── main.tf
│   ├── network.tf
│   ├── compute.tf
│   ├── iam.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── credentials.json          ← gitignored
├── ansible/
│   ├── gen_inventory.sh
│   ├── inventory.ini             ← gitignored (generated)
│   ├── playbook.yml
│   └── roles/
│       ├── docker/
│       │   └── tasks/main.yml
│       ├── kafka/
│       │   ├── tasks/main.yml
│       │   └── templates/docker-compose.yml.j2
│       └── elk/
│           ├── tasks/main.yml
│           └── templates/docker-compose.yml.j2
├── producer/
│   ├── producer.py
│   └── requirements.txt
├── consumer/
│   ├── consumer.py
│   ├── Dockerfile
│   └── requirements.txt
├── Makefile
├── .gitignore
├── DECISIONS.md
└── README.md
```

---

## .gitignore

```
terraform/credentials.json
terraform/.terraform/
terraform/terraform.tfstate*
terraform/terraform.tfvars
ansible/inventory.ini
**/__pycache__/
*.pyc
*.log
```

---

## Day 1 — GCP prerequisites + Terraform

### Step 1: GCP bootstrap (manual, once)

```bash
gcloud auth login
gcloud config set project gcp-log-pipeline

# Enable required APIs
gcloud services enable compute.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable iam.googleapis.com

# Create Terraform state bucket
gcloud storage buckets create gs://gcp-log-pipeline-tfstate-lausbelphegor \
  --location=europe-west1 \
  --uniform-bucket-level-access

# Create Terraform service account
gcloud iam service-accounts create terraform \
  --display-name="Terraform"

# Grant least-privilege roles (NOT roles/editor)
for role in \
  roles/compute.admin \
  roles/iam.serviceAccountUser \
  roles/storage.admin \
  roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding gcp-log-pipeline \
    --member="serviceAccount:terraform@gcp-log-pipeline.iam.gserviceaccount.com" \
    --role="$role"
done

# Download key
gcloud iam service-accounts keys create ./terraform/credentials.json \
  --iam-account=terraform@gcp-log-pipeline.iam.gserviceaccount.com
```

### Step 2: Terraform files

**backend.tf**

```hcl
terraform {
  backend "gcs" {
    bucket = "gcp-log-pipeline-tfstate-lausbelphegor"
    prefix = "log-pipeline/state"
  }
}
```

**main.tf**

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  credentials = file(var.credentials_file)
  project     = var.project_id
  region      = var.region
  zone        = var.zone
}
```

**variables.tf**

```hcl
variable "project_id"       { type = string }
variable "region"           { default = "europe-west1" }
variable "zone"             { default = "europe-west1-b" }
variable "credentials_file" { default = "./credentials.json" }
variable "machine_type"     { default = "e2-medium" }
variable "ssh_pub_key_path" { default = "~/.ssh/id_ed25519.pub" }
variable "your_ip" {
  type        = string
  description = "Your public IP in CIDR notation, e.g. 1.2.3.4/32"
}
```

**terraform.tfvars** (gitignored)

```hcl
project_id = "gcp-log-pipeline"
your_ip    = "YOUR.PUBLIC.IP.HERE/32"
```

**network.tf**

```hcl
resource "google_compute_network" "pipeline_vpc" {
  name                    = "pipeline-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "pipeline_subnet" {
  name          = "pipeline-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.pipeline_vpc.id
}

# SSH from your IP only
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.pipeline_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = [var.your_ip]
}

# Internal VPC traffic: Kafka, ES, Zookeeper
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.pipeline_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["9092", "9200", "2181", "29092"]
  }
  source_ranges = ["10.0.1.0/24"]
}

# Kibana UI from your IP only
resource "google_compute_firewall" "allow_kibana" {
  name    = "allow-kibana"
  network = google_compute_network.pipeline_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["5601"]
  }
  source_ranges = [var.your_ip]
}

# Kafka external from your IP (local producer needs this — GAP-01 fix)
resource "google_compute_firewall" "allow_kafka_external" {
  name        = "allow-kafka-external"
  network     = google_compute_network.pipeline_vpc.name
  target_tags = ["kafka"]
  allow {
    protocol = "tcp"
    ports    = ["9092"]
  }
  source_ranges = [var.your_ip]
}
```

**compute.tf**

```hcl
data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_compute_instance" "kafka" {
  name         = "kafka-instance"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.pipeline_subnet.id
    access_config {}
  }

  metadata = {
    ssh-keys = "debian:${file(var.ssh_pub_key_path)}"
  }

  tags = ["kafka"]
}

resource "google_compute_instance" "elk" {
  name         = "elk-instance"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.pipeline_subnet.id
    access_config {}
  }

  metadata = {
    ssh-keys = "debian:${file(var.ssh_pub_key_path)}"
  }

  tags = ["elk"]
}
```

**outputs.tf**

```hcl
output "kafka_public_ip"  { value = google_compute_instance.kafka.network_interface[0].access_config[0].nat_ip }
output "kafka_private_ip" { value = google_compute_instance.kafka.network_interface[0].network_ip }
output "elk_public_ip"    { value = google_compute_instance.elk.network_interface[0].access_config[0].nat_ip }
output "elk_private_ip"   { value = google_compute_instance.elk.network_interface[0].network_ip }
```

### Step 3: Deploy

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

**End of day 1 goal:** Two running GCE instances, SSH accessible, state visible in GCS bucket.

---

## Day 2 — Ansible + Kafka

### Step 1: Inventory generation

**ansible/gen_inventory.sh**

```bash
#!/bin/bash
KAFKA_IP=$(cd ../terraform && terraform output -raw kafka_public_ip)
ELK_IP=$(cd ../terraform && terraform output -raw elk_public_ip)
KEY="${SSH_KEY_PATH:-~/.ssh/id_ed25519}"

cat > inventory.ini << EOF
[kafka]
${KAFKA_IP} ansible_user=debian ansible_ssh_private_key_file=${KEY}

[elk]
${ELK_IP} ansible_user=debian ansible_ssh_private_key_file=${KEY}
EOF
echo "Inventory written to ansible/inventory.ini"
```

```bash
cd ansible && bash gen_inventory.sh
```

### Step 2: Docker role

**ansible/roles/docker/tasks/main.yml**

```yaml
- name: Install prerequisites
  apt:
    name: [ca-certificates, curl, gnupg, python3-apt]
    update_cache: yes
  become: yes

- name: Create Docker keyring dir
  file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"
  become: yes

- name: Download Docker GPG key
  get_url:
    url: https://download.docker.com/linux/debian/gpg
    dest: /etc/apt/keyrings/docker.asc
    mode: "0644"
  become: yes

- name: Add Docker apt repository
  apt_repository:
    repo: >-
      deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc]
      https://download.docker.com/linux/debian
      {{ ansible_distribution_release }} stable
    state: present
    filename: docker
  become: yes

- name: Install Docker packages
  apt:
    name: [docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin]
    update_cache: yes
  become: yes

- name: Add debian user to docker group
  user:
    name: debian
    groups: docker
    append: yes
  become: yes
```

### Step 3: Kafka role

**ansible/roles/kafka/templates/docker-compose.yml.j2**

```yaml
services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    restart: unless-stopped

  kafka:
    image: confluentinc/cp-kafka:7.6.0
    depends_on: [zookeeper]
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      # Both listeners must be declared explicitly (GAP-02 fix)
      KAFKA_LISTENERS: INTERNAL://0.0.0.0:29092,EXTERNAL://0.0.0.0:9092
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://kafka:29092,EXTERNAL://{{ kafka_public_ip }}:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: INTERNAL
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
    restart: unless-stopped
```

**ansible/roles/kafka/tasks/main.yml**

```yaml
- name: Create /opt/kafka
  file:
    path: /opt/kafka
    state: directory
    owner: debian
    group: debian
  become: yes

- name: Deploy Kafka compose (with public IP templated in)
  template:
    src: docker-compose.yml.j2
    dest: /opt/kafka/docker-compose.yml
    owner: debian
    group: debian
  vars:
    kafka_public_ip: "{{ ansible_host }}"
  become: yes

- name: Start Kafka stack
  shell: docker compose up -d
  args:
    chdir: /opt/kafka
  become: yes

- name: Wait for Kafka to be ready
  shell: docker exec kafka-kafka-1 kafka-topics --bootstrap-server localhost:9092 --list
  register: kafka_ready
  retries: 12
  delay: 10
  until: kafka_ready.rc == 0
  become: yes

- name: Create app-logs topic
  shell: >
    docker exec kafka-kafka-1 kafka-topics
    --bootstrap-server localhost:9092
    --create --if-not-exists
    --topic app-logs
    --partitions 3
    --replication-factor 1
  become: yes
```

### Step 4: Playbook with tags (GAP-04 fix)

**ansible/playbook.yml**

```yaml
- name: Install Docker on all instances
  hosts: all
  tags: [docker]
  roles: [docker]

- name: Deploy Kafka
  hosts: kafka
  tags: [kafka]
  roles: [kafka]

- name: Deploy ELK
  hosts: elk
  tags: [elk]
  roles: [elk]
```

### Step 5: Deploy and verify

```bash
# Full deploy
ansible-playbook -i inventory.ini playbook.yml

# Or staged
ansible-playbook -i inventory.ini playbook.yml --tags docker
ansible-playbook -i inventory.ini playbook.yml --tags kafka

# Verify topic exists
ansible kafka -i inventory.ini -a \
  "docker exec kafka-kafka-1 kafka-topics --bootstrap-server localhost:9092 --list" \
  --become
```

**End of day 2 goal:** Kafka running, `app-logs` topic created and listable.

---

## Day 3 — ELK + Consumer + Producer

### Step 1: Consumer application

**consumer/requirements.txt**

```
kafka-python==2.0.2
elasticsearch==8.13.0
```

**consumer/consumer.py**

```python
import json
import os
import time
from kafka import KafkaConsumer
from elasticsearch import Elasticsearch
from elasticsearch.exceptions import ConnectionError as ESConnectionError

KAFKA_BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP"]
ES_HOST         = os.environ["ES_HOST"]
TOPIC           = os.environ.get("KAFKA_TOPIC", "app-logs")
INDEX           = "app-logs"

def wait_for_es(es, retries=15, delay=6):
    for i in range(retries):
        try:
            es.info()
            print("Elasticsearch ready.")
            return
        except ESConnectionError:
            print(f"ES not ready, retry {i+1}/{retries}...")
            time.sleep(delay)
    raise RuntimeError("Elasticsearch never became available.")

es = Elasticsearch(ES_HOST)
wait_for_es(es)

if not es.indices.exists(index=INDEX):
    es.indices.create(index=INDEX, mappings={
        "properties": {
            "timestamp":        {"type": "date"},
            "service":          {"type": "keyword"},
            "level":            {"type": "keyword"},
            "message":          {"type": "text"},
            "response_time_ms": {"type": "integer"},
            "request_id":       {"type": "keyword"},
        }
    })
    print(f"Index '{INDEX}' created.")

consumer = KafkaConsumer(
    TOPIC,
    bootstrap_servers=[KAFKA_BOOTSTRAP],
    value_deserializer=lambda m: json.loads(m.decode("utf-8")),
    group_id="elk-consumer-group",
    auto_offset_reset="earliest",
)

print(f"Consuming from {TOPIC}, indexing to {INDEX}...")
for msg in consumer:
    doc = msg.value
    es.index(index=INDEX, document=doc)
    print(f"Indexed: {doc['service']} [{doc['level']}] {doc['message']}")
```

**consumer/Dockerfile**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY consumer.py .
CMD ["python", "consumer.py"]
```

### Step 2: ELK role

**ansible/roles/elk/files/docker-compose.yml**

```yaml
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.13.0
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      # 1 GB heap: demo compromise to fit on e2-medium (GAP-05 fix — honest framing)
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - esdata:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    restart: unless-stopped

  kibana:
    image: docker.elastic.co/kibana/kibana:8.13.0
    depends_on: [elasticsearch]
    environment:
      ELASTICSEARCH_HOSTS: http://elasticsearch:9200
    ports:
      - "5601:5601"
    restart: unless-stopped

  consumer:
    build: /opt/consumer
    depends_on: [elasticsearch]
    environment:
      KAFKA_BOOTSTRAP: "${KAFKA_PRIVATE_IP}:9092"
      ES_HOST: http://elasticsearch:9200
      KAFKA_TOPIC: app-logs
    restart: unless-stopped

volumes:
  esdata:
```

**ansible/roles/elk/tasks/main.yml**

```yaml
- name: Set vm.max_map_count for Elasticsearch
  sysctl:
    name: vm.max_map_count
    value: "262144"
    state: present
    reload: yes
  become: yes

- name: Create /opt/elk
  file:
    path: /opt/elk
    state: directory
    owner: debian
    group: debian
  become: yes

# Copy consumer source to ELK host (GAP-03 fix)
- name: Create /opt/consumer
  file:
    path: /opt/consumer
    state: directory
    owner: debian
    group: debian
  become: yes

- name: Sync consumer source
  synchronize:
    src: "../../../../consumer/"
    dest: /opt/consumer/
  become: yes

- name: Deploy ELK compose (with Kafka private IP injected)
  template:
    src: docker-compose.yml.j2
    dest: /opt/elk/docker-compose.yml
    owner: debian
    group: debian
  vars:
    kafka_private_ip: "{{ hostvars[groups['kafka'][0]]['ansible_host'] }}"
  become: yes

- name: Start ELK stack
  shell: docker compose up -d --build
  args:
    chdir: /opt/elk
  become: yes
```

Note: convert `docker-compose.yml` to a `.j2` template and replace `${KAFKA_PRIVATE_IP}` with `{{ kafka_private_ip }}`.

### Step 3: Producer application

**producer/requirements.txt**

```
kafka-python==2.0.2
```

**producer/producer.py**

```python
import json
import os
import random
import time
from datetime import datetime, timezone
from kafka import KafkaProducer

KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "localhost:9092")
TOPIC           = os.environ.get("KAFKA_TOPIC", "app-logs")

SERVICES = ["api-gateway", "auth-service", "payment-service", "notification-service"]
LEVELS   = ["INFO", "INFO", "INFO", "WARN", "ERROR"]
MESSAGES = {
    "INFO":  ["Request processed", "User logged in", "Cache hit", "DB query ok"],
    "WARN":  ["Slow query detected", "Retry attempt", "High memory usage"],
    "ERROR": ["Connection timeout", "Payment failed", "Auth token expired"],
}

producer = KafkaProducer(
    bootstrap_servers=[KAFKA_BOOTSTRAP],
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)

def generate_log():
    level = random.choice(LEVELS)
    return {
        "timestamp":        datetime.now(timezone.utc).isoformat(),
        "service":          random.choice(SERVICES),
        "level":            level,
        "message":          random.choice(MESSAGES[level]),
        "response_time_ms": random.randint(10, 2000) if level == "INFO" else None,
        "request_id":       f"req-{random.randint(10000, 99999)}",
    }

print(f"Producing to {KAFKA_BOOTSTRAP} / {TOPIC} — Ctrl+C to stop.")
while True:
    log = generate_log()
    producer.send(TOPIC, log)
    print(f"[{log['level']}] {log['service']}: {log['message']}")
    time.sleep(random.uniform(0.1, 0.5))
```

### Step 4: Deploy ELK + run producer

```bash
# Deploy ELK (includes consumer sync and build)
ansible-playbook -i inventory.ini playbook.yml --tags elk

# Get Kafka public IP
KAFKA_IP=$(cd ../terraform && terraform output -raw kafka_public_ip)

# Run producer locally
cd ../producer
pip install -r requirements.txt
KAFKA_BOOTSTRAP="${KAFKA_IP}:9092" python producer.py
```

### Step 5: Kibana setup

1. Open `http://ELK_PUBLIC_IP:5601` — wait up to 90 seconds for startup
2. Stack Management → Data Views → Create data view: name `app-logs`, index pattern `app-logs`, time field `timestamp`
3. Build two visualizations:
   - Bar chart: count by `level` (keyword)
   - Line chart: count over time (1-minute buckets)
4. Save both to a dashboard named `Log Pipeline Overview`
5. Screenshot the dashboard — this is your CV evidence

**End of day 3 goal:** Producer running locally, logs flowing through Kafka into ES, dashboard showing live data.

---

## Day 4 — Polish, README, destroy

### Makefile

```makefile
.PHONY: init apply destroy deploy deploy-kafka deploy-elk produce

KAFKA_IP := $(shell cd terraform && terraform output -raw kafka_public_ip 2>/dev/null)

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

destroy:
	cd terraform && terraform destroy

inventory:
	cd ansible && bash gen_inventory.sh

deploy: inventory
	cd ansible && ansible-playbook -i inventory.ini playbook.yml

deploy-kafka: inventory
	cd ansible && ansible-playbook -i inventory.ini playbook.yml --tags kafka

deploy-elk: inventory
	cd ansible && ansible-playbook -i inventory.ini playbook.yml --tags elk

produce:
	cd producer && KAFKA_BOOTSTRAP="$(KAFKA_IP):9092" python producer.py
```

### DECISIONS.md

```markdown
# Design decisions

This is a demo-tier deployment, not production-ready infrastructure.
Shortcuts made intentionally:

| Decision                                | Why acceptable here                    | What changes in prod                   |
| --------------------------------------- | -------------------------------------- | -------------------------------------- |
| Single-broker Kafka, single-node ES     | Demo scope, cost                       | Kafka cluster + ES cluster             |
| xpack.security disabled                 | ES not publicly exposed                | TLS + API keys                         |
| Terraform SA with compute/storage roles | Scoped, not roles/editor               | Workload Identity, shorter-lived creds |
| Static JSON key for Terraform           | Local dev only                         | ADC or CI-injected credentials         |
| Docker Compose, not GKE                 | Ops overhead unjustified at this scale | GKE or Cloud Run for services          |
| Zookeeper-based Kafka                   | Simpler, well-documented               | KRaft (ZK-less) for new deployments    |
| Public IPs on both VMs                  | SSH convenience                        | Private IPs + IAP tunnel or bastion    |
| ES heap 1 GB                            | Fits on e2-medium                      | Size to 50% of available RAM           |
| No index lifecycle management           | Demo data is small                     | ILM policy for hot/warm/delete         |

**Why Kafka instead of writing directly to Elasticsearch:**
Kafka decouples producers from the indexing pipeline. If Elasticsearch is
slow or restarting, producers keep writing to Kafka without dropping events.
The consumer reads at its own pace and can replay from any offset. Direct
writes mean a slow ES creates back-pressure or dropped logs on the application.
```

### README structure

1. One-paragraph what this is and why Kafka is justified
2. Architecture diagram (the ASCII version is fine)
3. Prerequisites: gcloud, terraform, ansible, python3, your public IP
4. Step-by-step: bootstrap → terraform apply → make deploy → make produce
5. Kibana screenshot
6. Link to DECISIONS.md
7. `make destroy` reminder with cost note

### Final cleanup and destroy

```bash
# Before destroying — take the Kibana screenshot first
make destroy
# Confirm all resources gone
gcloud compute instances list --project=gcp-log-pipeline
```

---

## Pitfalls reference

| Pitfall                                  | Symptom                                     | Fix                                                                                                          |
| ---------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Producer can't connect to Kafka          | `NoBrokersAvailable`                        | Check `allow_kafka_external` firewall rule exists; verify `KAFKA_ADVERTISED_LISTENERS` has correct public IP |
| Kafka dual-listener broken               | Consumer can't reach broker from inside VPC | Confirm `KAFKA_LISTENERS` is set explicitly; internal listener must be `INTERNAL://0.0.0.0:29092`            |
| ES won't start                           | Container exits immediately                 | Check `vm.max_map_count` was set; `docker logs elk-elasticsearch-1`                                          |
| ES OOM                                   | Container keeps restarting                  | Upgrade ELK instance to `e2-standard-2`; raise heap to 2g                                                    |
| Kibana not reachable                     | Connection refused on :5601                 | Wait 90 seconds; it is slow to start                                                                         |
| Consumer can't reach ES                  | Connection refused or timeout               | ES readiness wait in consumer handles this; check `depends_on` in compose                                    |
| Consumer can't reach Kafka from ELK host | Topic fetch fails                           | Confirm Kafka private IP is correctly templated into compose env var                                         |
| Ansible tags not working                 | Full playbook runs instead of subset        | Tags are on the play level in playbook.yml, not task level — `--tags kafka` targets the play                 |
| `synchronize` fails                      | rsync not found                             | `apt install rsync` on controller and target, or use `copy` module instead                                   |

---

## CV bullet (final)

```
GCP Log Pipeline                                   github.com/YOU/gcp-log-pipeline
Designed and deployed a log ingestion and observability platform on GCP.
- Provisioned VPC, firewall rules, and GCE instances with Terraform;
  remote state stored in GCS
- Automated instance configuration and service deployment with Ansible
- Implemented Kafka producer/consumer pipeline in Python; structured
  events indexed into Elasticsearch with explicit field mappings
- Built Kibana dashboard for real-time log-level monitoring and
  service health visibility
- Stack: Terraform · GCP · Kafka · Elasticsearch · Kibana · Docker · Ansible · Python
```
