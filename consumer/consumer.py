import json
import os
import sys
import time

from elasticsearch import Elasticsearch
from kafka import KafkaConsumer


KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "localhost:9092")
ES_HOST = os.environ.get("ES_HOST", "http://localhost:9200")
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "app-logs")

INDEX_NAME = "app-logs"
INDEX_MAPPING = {
    "properties": {
        "timestamp":        {"type": "date"},
        "service":          {"type": "keyword"},
        "level":            {"type": "keyword"},
        "message":          {"type": "text"},
        "response_time_ms": {"type": "integer"},
        "request_id":       {"type": "keyword"},
    }
}


def wait_for_es(es):
    for attempt in range(1, 16):
        try:
            es.info()
            print(f"Elasticsearch reachable at {ES_HOST}")
            return
        except Exception as e:
            print(f"ES not ready (attempt {attempt}/15): {e}")
            time.sleep(6)
    print("Elasticsearch never became ready; exiting")
    sys.exit(1)


def ensure_index(es):
    if not es.indices.exists(index=INDEX_NAME):
        es.indices.create(index=INDEX_NAME, mappings=INDEX_MAPPING)
        print(f"Created index {INDEX_NAME}")
    else:
        print(f"Index {INDEX_NAME} already exists")


def main():
    es = Elasticsearch(ES_HOST)
    wait_for_es(es)
    ensure_index(es)

    consumer = KafkaConsumer(
        KAFKA_TOPIC,
        bootstrap_servers=KAFKA_BOOTSTRAP,
        group_id="elk-consumer-group",
        auto_offset_reset="earliest",
        value_deserializer=lambda m: json.loads(m.decode("utf-8")),
    )
    print(f"Consuming from {KAFKA_BOOTSTRAP} topic={KAFKA_TOPIC}")

    try:
        for msg in consumer:
            try:
                es.index(index=INDEX_NAME, document=msg.value)
            except Exception as e:
                print(f"Index failed: {e}")
    except KeyboardInterrupt:
        print("Stopping consumer")
    finally:
        consumer.close()


if __name__ == "__main__":
    main()
