"""Онлайн бібліотека — контейнерна версія Lambda-застосунку з ЛР-8 (ЛР-9).

Невеликий HTTP-сервер на стандартній бібліотеці Python, який викликає ту саму
бізнес-логіку handler.handle(), що й Lambda. Дані — у тій самій таблиці DynamoDB
в LocalStack, тому екземпляри без стану (stateless) і їх можна балансувати.

Кожна відповідь містить заголовок X-Instance з ідентифікатором екземпляра
(змінна INSTANCE_ID: app1, app2, app3), а /health повертає його в тілі.

ЛР-10: кожен запит до /books записується в метрики CloudWatch (metrics.py).
Для експериментів можна штучно погіршити роботу:
    FAIL_RATE  частка запитів (0..1), які отримують 500
    DELAY_MS   додаткова затримка кожного запиту, мс
/health ці налаштування не зачіпають — інакше Docker вважав би екземпляр несправним.
"""

import json
import os
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from botocore.exceptions import ClientError, EndpointConnectionError

import handler
from metrics import MetricsPublisher

PORT = int(os.environ.get("PORT", "8000"))
FAIL_RATE = float(os.environ.get("FAIL_RATE", "0"))
DELAY_MS = float(os.environ.get("DELAY_MS", "0"))
METRICS_ENABLED = os.environ.get("METRICS_ENABLED", "false").lower() == "true"
metrics = None  # MetricsPublisher, створюється при запуску


def log(**fields):
    print(json.dumps({"instance": handler.INSTANCE_ID, **fields}, ensure_ascii=False), flush=True)


def ensure_table(retries=60, delay=2):
    """Створює таблицю Books, якщо її ще немає (кілька екземплярів стартують одночасно)."""
    endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
    client = boto3.client("dynamodb", endpoint_url=endpoint)
    for _ in range(retries):
        try:
            client.describe_table(TableName=handler.TABLE_NAME)
            return True
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ResourceNotFoundException":
                raise
            try:
                client.create_table(
                    TableName=handler.TABLE_NAME,
                    AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
                    KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
                    BillingMode="PAY_PER_REQUEST",
                )
                log(level="info", msg="table created", table=handler.TABLE_NAME)
            except ClientError as create_exc:
                if create_exc.response["Error"]["Code"] != "ResourceInUseException":
                    raise
        except EndpointConnectionError:
            log(level="warning", msg="DynamoDB is not ready, retrying")
        time.sleep(delay)
    raise RuntimeError("DynamoDB is not available")


class Handler(BaseHTTPRequestHandler):
    server_version = "online-library"

    def _serve(self, method):
        start = time.perf_counter()
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8") if length else ""
        body = body.lstrip("\ufeff")  # Windows PowerShell 5.1 може додати BOM
        path = self.path.split("?", 1)[0]
        service_path = path.rstrip("/").endswith("/health")
        try:
            if not service_path and DELAY_MS > 0:
                time.sleep(DELAY_MS / 1000)
            if not service_path and random.random() < FAIL_RATE:
                status, payload = 500, {"error": "injected failure"}
            else:
                status, payload = handler.handle(method, path, body)
        except Exception as exc:  # noqa: BLE001 — будь-яка помилка БД -> 500
            log(level="error", msg="unhandled", error=str(exc))
            status, payload = 500, {"error": "internal server error"}
        data = b"" if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Instance", handler.INSTANCE_ID)
        self.end_headers()
        if data:
            self.wfile.write(data)
        self.last = (status, round((time.perf_counter() - start) * 1000, 1))
        if metrics is not None and not service_path:
            metrics.record(status, self.last[1])
        log(level="info", method=method, path=self.path, status=status, duration_ms=self.last[1])

    def do_GET(self):
        self._serve("GET")

    def do_POST(self):
        self._serve("POST")

    def do_DELETE(self):
        self._serve("DELETE")

    def log_message(self, format, *args):  # noqa: A002 — замість стандартного логу пишемо JSON
        pass


def make_server(port=PORT):
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)


if __name__ == "__main__":
    ensure_table()
    if METRICS_ENABLED:
        metrics = MetricsPublisher()
        metrics.start(log)
    log(
        level="info",
        msg="listening",
        port=PORT,
        fail_rate=FAIL_RATE,
        delay_ms=DELAY_MS,
        metrics=METRICS_ENABLED,
    )
    make_server().serve_forever()
