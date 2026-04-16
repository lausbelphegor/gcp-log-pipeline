resource "google_service_account" "kafka_vm_sa" {
  account_id   = "kafka-vm-sa"
  display_name = "Kafka VM service account"
  description  = "Dedicated identity for kafka-instance. No project roles bound — least privilege for a VM that makes no GCP API calls."
}

resource "google_service_account" "elk_vm_sa" {
  account_id   = "elk-vm-sa"
  display_name = "ELK VM service account"
  description  = "Dedicated identity for elk-instance. No project roles bound — least privilege for a VM that makes no GCP API calls."
}

# No google_project_iam_member resources here by design.
# These SAs intentionally start with zero project-level roles.
# See DECISIONS.md "Dedicated service accounts for VMs" for rationale.
