import json
import os
import random
import time
from datetime import datetime, timezone

from kafka import KafkaProducer


KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "localhost:9092")
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "app-logs")

SERVICES = [
    "api-gateway",
    "auth-service",
    "payment-service",
    "notification-service",
]

LEVELS = ["INFO", "WARN", "ERROR"]
WEIGHTS = [0.6, 0.2, 0.2]

MESSAGES = {
    "INFO": [
        "Request processed successfully",
        "User login successful",
        "Cache hit",
        "Health check OK",
    ],
    "WARN": [
        "Slow response detected",
        "Rate limit approaching",
        "Cache miss",
        "Deprecated endpoint called",
    ],
    "ERROR": [
        "Database connection failed",
        "Payment failed",
        "Unhandled exception",
        "Upstream service timeout",
    ],
}


def make_event():
    level = random.choices(LEVELS, weights=WEIGHTS, k=1)[0]
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service": random.choice(SERVICES),
        "level": level,
        "message": random.choice(MESSAGES[level]),
        "response_time_ms": random.randint(10, 500) if level == "INFO" else None,
        "request_id": f"req-{random.randint(0, 99999):05d}",
    }


def main():
    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP,
        value_serializer=lambda v: json.dumps(v, default=str).encode("utf-8"),
    )
    print(f"Producing to {KAFKA_BOOTSTRAP} topic={KAFKA_TOPIC}")
    try:
        while True:
            event = make_event()
            producer.send(KAFKA_TOPIC, event)
            print(event)
            time.sleep(random.uniform(0.1, 0.5))
    except KeyboardInterrupt:
        print("Stopping producer")
    finally:
        producer.flush()
        producer.close()


if __name__ == "__main__":
    main()
