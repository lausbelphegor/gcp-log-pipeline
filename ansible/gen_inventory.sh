#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

KAFKA_PUBLIC_IP=$(terraform -chdir="$TF_DIR" output -raw kafka_public_ip)
KAFKA_PRIVATE_IP=$(terraform -chdir="$TF_DIR" output -raw kafka_private_ip)
ELK_PUBLIC_IP=$(terraform -chdir="$TF_DIR" output -raw elk_public_ip)
ELK_PRIVATE_IP=$(terraform -chdir="$TF_DIR" output -raw elk_private_ip)

# elk_private_ip is read to verify the Terraform output interface is intact.
# It has no current consumer in the inventory but confirms all four outputs exist.
: "${ELK_PRIVATE_IP}"

cat > "$SCRIPT_DIR/inventory.ini" <<EOF
[kafka]
${KAFKA_PUBLIC_IP} ansible_user=debian ansible_ssh_private_key_file=~/.ssh/id_ed25519 kafka_private_ip=${KAFKA_PRIVATE_IP}

[elk]
${ELK_PUBLIC_IP} ansible_user=debian ansible_ssh_private_key_file=~/.ssh/id_ed25519

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

echo "Written: $SCRIPT_DIR/inventory.ini"
