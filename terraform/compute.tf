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

  labels = {
    project    = "log-pipeline"
    env        = "demo"
    managed_by = "terraform"
  }

  service_account {
    email = google_service_account.kafka_vm_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
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

  labels = {
    project    = "log-pipeline"
    env        = "demo"
    managed_by = "terraform"
  }

  service_account {
    email = google_service_account.elk_vm_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  tags = ["elk"]
}
