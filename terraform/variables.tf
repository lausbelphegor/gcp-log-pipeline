variable "project_id" { type = string }
variable "region" { default = "europe-west1" }
variable "zone" { default = "europe-west1-b" }
variable "credentials_file" { default = "./credentials.json" }
variable "machine_type" { default = "e2-medium" }
variable "ssh_pub_key_path" { default = "~/.ssh/id_ed25519.pub" }
variable "your_ip" {
  type        = string
  description = "Your public IP in CIDR notation, e.g. 1.2.3.4/32"
}
