# consumer/

Reads events from Kafka and indexes them into Elasticsearch. Runs on the ELK GCE instance as a Docker container, built on the host during deploy.

## Files

| File               | Purpose                                        |
| ------------------ | ---------------------------------------------- |
| `consumer.py`      | Main application                               |
| `Dockerfile`       | Builds from `python:3.12-slim`                 |
| `requirements.txt` | `kafka-python==2.2.11`, `elasticsearch==8.13.0` |

## Deployment

This is NOT run locally. It is:

1. Synced to the ELK host at `/opt/consumer/` by the Ansible elk role (`synchronize` module)
2. Built on the ELK host by `docker compose up --build`
3. Run as the `consumer` service in `/opt/elk/docker-compose.yml`

To redeploy after code changes:

```bash
make deploy-elk
```

This re-syncs source and rebuilds the image on the host.

To view logs of the running consumer:

```bash
ssh debian@ELK_IP "docker logs elk-consumer-1 -f"
```

## Environment variables

Set by Ansible in `/opt/elk/docker-compose.yml` at deploy time:

| Variable          | Value                       | Notes                                    |
| ----------------- | --------------------------- | ---------------------------------------- |
| `KAFKA_BOOTSTRAP` | `<kafka_private_ip>:19092`  | Private IP + BROKER listener port — traffic stays inside VPC |
| `ES_HOST`         | `http://elasticsearch:9200` | Docker Compose service name              |
| `KAFKA_TOPIC`     | `app-logs`                  | Must match producer and Kafka topic name |

## Startup behavior

On start, the consumer:

1. Connects to Elasticsearch and calls `es.info()` — retries up to 15 times with 6s delay
2. Creates the `app-logs` index with explicit mappings if it does not exist
3. Starts consuming from Kafka with `auto_offset_reset="earliest"`

The retry loop means the consumer handles ES being slow to start. Do not remove it — `depends_on: elasticsearch` in Compose only waits for the container to start, not for ES to be ready.

## Elasticsearch index mapping

Defined in `consumer.py` and applied once on first run:

```python
{
    "timestamp":        {"type": "date"},
    "service":          {"type": "keyword"},
    "level":            {"type": "keyword"},
    "message":          {"type": "text"},
    "response_time_ms": {"type": "integer"},
    "request_id":       {"type": "keyword"},
}
```

`service` and `level` are `keyword` (exact match, aggregatable). `message` is `text` (full-text searchable). If you change these, delete and recreate the index — ES does not allow field type changes in place.

## Consumer group

Consumer group ID: `elk-consumer-group`

This means offsets are committed to Kafka. If the consumer restarts, it resumes from where it left off. If you want to reprocess all events from the beginning, either:

- Delete the consumer group: `docker exec kafka-kafka-1 kafka-consumer-groups --bootstrap-server kafka:29092 --delete --group elk-consumer-group`
- Or delete and recreate the ES index, then restart the consumer

## Indexing behavior

Events are indexed one at a time with `es.index()`. This is intentionally simple — at demo throughput (~2–10 events/sec) it is sufficient. Do not switch to bulk indexing unless you have a specific reason — it adds complexity and the current approach is readable.

## Error handling

The consumer has no retry logic for individual indexing failures. If ES rejects a document (e.g. type mismatch), the error is printed and the consumer continues. This is intentional — for a demo, losing occasional events is acceptable. Do not add complex dead-letter queue logic.

## Do not modify

- The ES readiness retry loop — removing it causes startup failures when ES is slow
- The index mapping field types for existing fields without also deleting the index
- The consumer group ID without considering offset implications
- `auto_offset_reset="earliest"` — changing to `"latest"` means the dashboard will not backfill events produced before the consumer started
