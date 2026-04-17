.DEFAULT_GOAL := help

TF_DIR  ?= terraform
ANS_DIR ?= ansible
TF_CMD   = terraform -chdir=$(TF_DIR)

ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: help check-creds init plan apply destroy outputs inventory ping \
        deploy deploy-docker deploy-kafka deploy-elk produce kibana clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-creds: ## Verify terraform/credentials.json exists
	@test -f $(TF_DIR)/credentials.json || { \
	  echo "ERROR: $(TF_DIR)/credentials.json not found. Place the GCP service-account key there before running terraform."; \
	  exit 1; }

init: check-creds ## terraform init
	$(TF_CMD) init

plan: check-creds ## terraform plan
	$(TF_CMD) plan

apply: check-creds ## terraform apply
	$(TF_CMD) apply

destroy: ## terraform destroy
	$(TF_CMD) destroy

outputs: ## terraform output
	$(TF_CMD) output

inventory: ## Generate ansible/inventory.ini from terraform outputs
	bash $(ANS_DIR)/gen_inventory.sh

ping: ## Ansible ping all hosts
	ansible all -i $(ANS_DIR)/inventory.ini -m ping

deploy: inventory ## Run full ansible playbook (all roles)
	ansible-playbook -i $(ANS_DIR)/inventory.ini $(ANS_DIR)/playbook.yml

deploy-docker: ## Run ansible playbook with --tags docker
	ansible-playbook -i $(ANS_DIR)/inventory.ini $(ANS_DIR)/playbook.yml --tags docker

deploy-kafka: ## Run ansible playbook with --tags kafka
	ansible-playbook -i $(ANS_DIR)/inventory.ini $(ANS_DIR)/playbook.yml --tags kafka

deploy-elk: ## Run ansible playbook with --tags elk
	ansible-playbook -i $(ANS_DIR)/inventory.ini $(ANS_DIR)/playbook.yml --tags elk

produce: ## Run producer with KAFKA_BOOTSTRAP from terraform output
	cd "$(ROOT_DIR)" && \
	KAFKA_BOOTSTRAP=$$($(TF_CMD) output -raw kafka_public_ip):9092 \
	python producer/producer.py

kibana: ## Print Kibana URL from terraform output
	@echo "Open http://$$($(TF_CMD) output -raw elk_public_ip):5601 in your browser"

clean: ## Remove ansible/inventory.ini
	rm -f $(ANS_DIR)/inventory.ini
