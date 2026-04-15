# producer/

Generates fake structured log events and publishes them to Kafka. Runs locally — not deployed to GCP.

## Files

| File               | Purpose               |
| ------------------ | --------------------- |
| `producer.py`      | Main script           |
| `requirements.txt` | `kafka-python==2.0.2` |

## Running

```bash
pip install -r requirements.txt

# Quickest way via Makefile (reads Kafka IP from terraform output automatically)
make produce

# Or manually
KAFKA_BOOTSTRAP="<kafka_public_ip>:9092" python producer.py
```

The Kafka public IP comes from `terraform output kafka_public_ip`.

## Environment variables

| Variable          | Default          | Notes                                                                    |
| ----------------- | ---------------- | ------------------------------------------------------------------------ |
| `KAFKA_BOOTSTRAP` | `localhost:9092` | Must be set to Kafka public IP:9092 for real use                         |
| `KAFKA_TOPIC`     | `app-logs`       | Change only if you also change the topic name in consumer and Kafka role |

## Event schema

Every event is a JSON object:

```json
{
  "timestamp": "2024-01-15T10:30:00.000000+00:00",
  "service": "payment-service",
  "level": "ERROR",
  "message": "Payment failed",
  "response_time_ms": null,
  "request_id": "req-42301"
}
```

Field rules:

- `timestamp` — always UTC ISO 8601. Do not change the format — Elasticsearch maps this field as `date` and parses this format.
- `service` — one of: `api-gateway`, `auth-service`, `payment-service`, `notification-service`
- `level` — one of: `INFO`, `WARN`, `ERROR`. Distribution is weighted (INFO ~60%, WARN ~20%, ERROR ~20%).
- `response_time_ms` — integer only on INFO events, `None` (serialized as `null`) on WARN/ERROR. Do not set it on non-INFO events — the Kibana chart for response time filters on INFO only.
- `request_id` — format `req-NNNNN`. Must stay as a string.

## Modifying event shape

If you add or rename fields, you must also:

1. Update the Elasticsearch index mapping in `consumer/consumer.py` (`INDEX_MAPPING`)
2. Delete the existing ES index and recreate it (mapping changes are not automatic): `curl -X DELETE http://ELK_IP:9200/app-logs`
3. Update the Kibana Data View if field types change

Do not change field types of existing fields without doing all three steps above.

## Throughput

Default sleep is `random.uniform(0.1, 0.5)` seconds between events (~2–10 events/sec). This is intentionally low to avoid overwhelming the demo infrastructure. Do not remove the sleep — ES on e2-medium under sustained high ingest will fall behind and eventually OOM.
