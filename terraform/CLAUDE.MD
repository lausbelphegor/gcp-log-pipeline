# terraform/

Provisions all GCP infrastructure for gcp-log-pipeline.

## Files

| File               | Purpose                                                               |
| ------------------ | --------------------------------------------------------------------- |
| `backend.tf`       | GCS remote state config — do not edit bucket name                     |
| `main.tf`          | Provider config                                                       |
| `variables.tf`     | All input variable declarations                                       |
| `terraform.tfvars` | Your values for `project_id` and `your_ip` — gitignored, never commit |
| `network.tf`       | VPC, subnet, all firewall rules                                       |
| `compute.tf`       | GCE instances and disk config                                         |
| `outputs.tf`       | Public/private IPs — consumed by Ansible inventory script             |
| `credentials.json` | GCP SA key — gitignored, never read or print this file                |

## Workflow

```bash
terraform init      # required once and after provider version changes
terraform plan      # always review before apply
terraform apply     # creates/updates infra
terraform destroy   # run when done — two e2-medium instances cost ~$0.07/hr combined
terraform output    # show current IPs
```

## Variables

All variables are declared in `variables.tf`. The only ones that require user input (no default) are:

- `project_id` — GCP project ID, set in `terraform.tfvars`
- `your_ip` — your public IP in CIDR notation (`x.x.x.x/32`), set in `terraform.tfvars`

To find your current public IP: `curl -s ifconfig.me`/32

If your IP changes (dynamic home IP), update `terraform.tfvars` and run `terraform apply` — only the firewall rules will be updated.

## Outputs

These four outputs are the interface with Ansible. Do not rename them — `ansible/gen_inventory.sh` reads them by name:

```
kafka_public_ip
kafka_private_ip
elk_public_ip
elk_private_ip
```

## State

Remote state lives in GCS at:
`gs://gcp-log-pipeline-tfstate-lausbelphegor/log-pipeline/state`

Do not run `terraform apply` from two places simultaneously — there is no state locking configured (DynamoDB-style locking is AWS; GCS backend supports object locking but it is not configured here). Single-developer project, this is fine.

## IAM

The Terraform service account (`terraform@gcp-log-pipeline.iam.gserviceaccount.com`) has these roles:

- `roles/compute.admin`
- `roles/iam.serviceAccountUser`
- `roles/storage.admin`
- `roles/serviceusage.serviceUsageConsumer`

It does NOT have `roles/editor`. Do not grant `roles/editor` — the above roles are sufficient for everything this Terraform config does.

## Adding resources

When adding new GCP resources:

1. Check whether the required API is enabled. If adding Cloud SQL, enable `sqladmin.googleapis.com`. If adding GKE, enable `container.googleapis.com`.
2. Check whether the Terraform SA has the required IAM role. If not, add it via `gcloud` before running apply.
3. Add firewall rules explicitly — the default VPC firewall is not used. All rules live in `network.tf`.
4. Add outputs for any IPs or hostnames that Ansible or the application needs.

## Do not modify

- The state bucket name in `backend.tf`
- The output names in `outputs.tf` (without also updating `ansible/gen_inventory.sh`)
- The VPC CIDR `10.0.1.0/24` (without also updating `allow_internal` source ranges)
- Instance tags `kafka` and `elk` (firewall rules target these tags)
