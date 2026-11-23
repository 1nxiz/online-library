"""ЛР-10: збір метрик запитів і публікація в Amazon CloudWatch (PutMetricData).

Кожен запит записується в буфер у пам'яті. Раз на FLUSH_SECONDS фоновий потік
надсилає в CloudWatch (простір імен OnlineLibrary, вимір Service=online-library):

    Requests  (Count)         кількість оброблених запитів за інтервал
    Errors    (Count)         кількість відповідей 5xx за інтервал
    Latency   (Milliseconds)  тривалість обробки кожного запиту (до 100 значень за інтервал)

З цих даних GetMetricData/GetMetricStatistics дають кількість запитів за період (Sum),
частку помилок (Errors/Requests) і середній час відповіді (Average).
"""

import os
import random
import threading
from datetime import UTC, datetime

import boto3

NAMESPACE = os.environ.get("METRICS_NAMESPACE", "OnlineLibrary")
SERVICE = os.environ.get("METRICS_SERVICE", "online-library")
FLUSH_SECONDS = float(os.environ.get("METRICS_FLUSH_SECONDS", "10"))
MAX_LATENCY_SAMPLES = 100  # вибірка для середнього — щоб не надсилати тисячі точок
BATCH = 20  # кількість MetricData в одному виклику PutMetricData


class MetricsPublisher:
    def __init__(self, client=None, namespace=NAMESPACE, service=SERVICE):
        endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
        self.client = client or boto3.client("cloudwatch", endpoint_url=endpoint)
        self.namespace = namespace
        self.dimensions = [{"Name": "Service", "Value": service}]
        self._lock = threading.Lock()
        self._reset()
        self._stop = threading.Event()
        self._thread = None
        self.published = 0  # скільки точок надіслано (для логів і тестів)

    def _reset(self):
        self.requests = 0
        self.errors = 0
        self.latencies = []

    def record(self, status, duration_ms):
        with self._lock:
            self.requests += 1
            if status >= 500:
                self.errors += 1
            self.latencies.append(float(duration_ms))

    def _take(self):
        with self._lock:
            snapshot = (self.requests, self.errors, self.latencies)
            self._reset()
        return snapshot

    def build_metric_data(self, requests, errors, latencies, now=None):
        now = now or datetime.now(UTC)
        if len(latencies) > MAX_LATENCY_SAMPLES:
            latencies = random.sample(latencies, MAX_LATENCY_SAMPLES)

        def datum(name, value, unit):
            return {
                "MetricName": name,
                "Dimensions": self.dimensions,
                "Timestamp": now,
                "Value": value,
                "Unit": unit,
            }

        data = [datum("Requests", requests, "Count"), datum("Errors", errors, "Count")]
        data += [datum("Latency", round(ms, 2), "Milliseconds") for ms in latencies]
        return data

    def flush(self):
        """Надіслати накопичене. Повертає кількість надісланих точок."""
        requests, errors, latencies = self._take()
        if requests == 0:
            return 0
        data = self.build_metric_data(requests, errors, latencies)
        for i in range(0, len(data), BATCH):
            self.client.put_metric_data(Namespace=self.namespace, MetricData=data[i : i + BATCH])
        self.published += len(data)
        return len(data)

    def _loop(self, log):
        while not self._stop.wait(FLUSH_SECONDS):
            try:
                sent = self.flush()
                if sent:
                    log(level="info", msg="metrics published", datapoints=sent)
            except Exception as exc:  # noqa: BLE001 — метрики не мають валити застосунок
                log(level="warning", msg="metrics publish failed", error=str(exc))

    def start(self, log=print):
        self._thread = threading.Thread(target=self._loop, args=(log,), daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self.flush()
