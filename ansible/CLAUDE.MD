# ansible/

Configures GCE instances and deploys all services for gcp-log-pipeline.

## Files

| File               | Purpose                                           |
| ------------------ | ------------------------------------------------- |
| `gen_inventory.sh` | Reads terraform outputs, writes `inventory.ini`   |
| `inventory.ini`    | Generated file — gitignored, do not edit manually |
| `playbook.yml`     | Entry point — three plays with tags               |
| `roles/docker/`    | Installs Docker CE on all hosts                   |
| `roles/kafka/`     | Deploys Kafka + Zookeeper                         |
| `roles/elk/`       | Deploys ES + Kibana + consumer                    |

## Workflow

Always regenerate inventory before running playbook — IPs change if instances are destroyed and recreated:

```bash
bash gen_inventory.sh
ansible-playbook -i inventory.ini playbook.yml
```

Staged deployment using tags:

```bash
ansible-playbook -i inventory.ini playbook.yml --tags docker   # all hosts
ansible-playbook -i inventory.ini playbook.yml --tags kafka    # kafka host only
ansible-playbook -i inventory.ini playbook.yml --tags elk      # elk host only
```

Tags are applied at the **play level** in `playbook.yml`, not the task level. `--tags kafka` runs the entire kafka play, not individual tasks.

Check connectivity before running:

```bash
ansible all -i inventory.ini -m ping
```

## Role responsibilities

### docker role

- Runs on: all hosts
- Installs Docker CE from Docker's official Debian repo using `get_url` + `apt_repository` (not raw shell)
- Adds `debian` user to `docker` group
- Must complete before kafka or elk roles run

### kafka role

- Runs on: kafka host
- Deploys `/opt/kafka/docker-compose.yml` from a Jinja2 template
- The template substitutes `{{ kafka_public_ip }}` with `ansible_host` — this is the Kafka external advertised listener
- Starts the stack with `docker compose up -d`
- Waits for broker readiness (retries kafka-topics --list)
- Creates `app-logs` topic (3 partitions, replication-factor 1)

### elk role

- Runs on: elk host
- Sets `vm.max_map_count=262144` via sysctl (Elasticsearch requires this)
- Syncs consumer source from `../consumer/` to `/opt/consumer/` on the remote host
- Deploys `/opt/elk/docker-compose.yml` from a Jinja2 template
- Injects Kafka private IP into consumer environment variable via `hostvars`
- Runs `docker compose up -d --build` (builds consumer image on the host)

## Jinja2 templates

Both kafka and elk roles use `.j2` templates, not static files:

**kafka role** — `roles/kafka/templates/docker-compose.yml.j2`

- Variable: `{{ kafka_public_ip }}` → substituted with `ansible_host` (the public IP Ansible is connecting through)
- Used in: `KAFKA_ADVERTISED_LISTENERS` external listener

**elk role** — `roles/elk/templates/docker-compose.yml.j2`

- Variable: `{{ kafka_private_ip }}` → substituted with `hostvars[groups['kafka'][0]]['kafka_private_ip']` (explicit host var written by gen_inventory.sh; `ansible_host` is the public SSH IP and must not be used here — that would route consumer traffic to the public internet instead of the VPC)
- Used in: consumer `KAFKA_BOOTSTRAP` environment variable
- Note: consumer uses private IP to keep traffic inside the VPC

## Consumer source sync

The elk role syncs `../consumer/` to `/opt/consumer/` on the ELK host using the `synchronize` module (rsync). This must happen before `docker compose up --build` or the build will fail with a missing context error.

If you modify any file in `consumer/`, re-run:

```bash
ansible-playbook -i inventory.ini playbook.yml --tags elk
```

This will re-sync the source and rebuild the Docker image.

## Debugging

If a role fails, run with `-v` or `-vvv` for verbose output:

```bash
ansible-playbook -i inventory.ini playbook.yml --tags kafka -v
```

Check Docker container state on a host:

```bash
ansible kafka -i inventory.ini -a "docker ps -a" --become
ansible elk -i inventory.ini -a "docker ps -a" --become
```

View container logs:

```bash
ansible kafka -i inventory.ini -a "docker logs kafka-kafka-1 --tail 50" --become
ansible elk -i inventory.ini -a "docker logs elk-elasticsearch-1 --tail 50" --become
ansible elk -i inventory.ini -a "docker logs elk-consumer-1 --tail 50" --become
```

## Do not modify

- `inventory.ini` — always generated, edits will be overwritten
- The Kafka `KAFKA_LISTENERS` line — both listeners must be declared explicitly, removing either breaks the external or internal path
- `vm.max_map_count` task — ES will not start without it
- The `synchronize` task in elk role — removing it breaks the consumer Docker build
