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
