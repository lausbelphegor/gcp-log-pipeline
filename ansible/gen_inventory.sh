#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

cd "${TF_DIR}"

KAFKA_PUBLIC_IP=$(terraform output -raw kafka_public_ip)
KAFKA_PRIVATE_IP=$(terraform output -raw kafka_private_ip)
ELK_PUBLIC_IP=$(terraform output -raw elk_public_ip)

cat > "${SCRIPT_DIR}/inventory.ini" <<EOF
[kafka]
${KAFKA_PUBLIC_IP} kafka_private_ip=${KAFKA_PRIVATE_IP}

[elk]
${ELK_PUBLIC_IP}

[all:vars]
ansible_user=debian
ansible_ssh_private_key_file=~/.ssh/id_ed25519
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

echo "inventory.ini written"
