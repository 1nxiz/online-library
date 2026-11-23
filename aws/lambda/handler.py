"""Онлайн бібліотека — serverless-версія (ЛР-8).

Одна Lambda-функція обробляє HTTP-запити від API Gateway (proxy integration)
і зберігає книги в DynamoDB. Та сама функція `handle()` використовується
HTTP-сервером у контейнерах ЛР-9/ЛР-10 (aws/app/server.py).

Маршрути:
    GET    /health          перевірка працездатності
    GET    /books           список книг
    POST   /books           створити книгу {"title", "author", "year"?}
    GET    /books/{id}      одна книга
    DELETE /books/{id}      видалити книгу
"""

import base64
import json
import os
import re
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import boto3

TABLE_NAME = os.environ.get("TABLE_NAME", "Books")
# ідентифікатор екземпляра: у Lambda — "lambda", у контейнерах ЛР-9 — app1/app2/app3
INSTANCE_ID = os.environ.get("INSTANCE_ID", "lambda")

# /books, /books/{id}, /health; працює і з префіксом стадії (/dev/books)
ROUTE = re.compile(r"/(books|health)(?:/([^/]+))?/?$")

_table = None


def table():
    """Таблиця DynamoDB. Адресу LocalStack Lambda отримує зі змінної AWS_ENDPOINT_URL."""
    global _table
    if _table is None:
        endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
        _table = boto3.resource("dynamodb", endpoint_url=endpoint).Table(TABLE_NAME)
    return _table


def _plain(value):
    """DynamoDB повертає числа як Decimal — перетворюємо для JSON."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_plain(v) for v in value]
    return value


def validate_book(data):
    """Повертає (book, error)."""
    if not isinstance(data, dict):
        return None, "body must be a JSON object"
    title = str(data.get("title") or "").strip()
    author = str(data.get("author") or "").strip()
    year = data.get("year")
    if not title:
        return None, "title is required"
    if not author:
        return None, "author is required"
    if year in (None, ""):
        year = None
    else:
        try:
            year = int(year)
        except (TypeError, ValueError):
            return None, "year must be a number"
        if year < 0 or year > 2100:
            return None, "year is out of range"
    return {"title": title, "author": author, "year": year}, None


def list_books():
    items, kwargs = [], {}
    while True:
        page = table().scan(**kwargs)
        items.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    items.sort(key=lambda b: b.get("created_at", ""))
    return _plain(items)


def create_book(book):
    item = {
        "id": uuid.uuid4().hex[:12],
        "title": book["title"],
        "author": book["author"],
        "available": True,
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
    }
    if book["year"] is not None:
        item["year"] = book["year"]
    table().put_item(Item=item)
    return _plain(item)


def get_book(book_id):
    item = table().get_item(Key={"id": book_id}).get("Item")
    return _plain(item) if item else None


def delete_book(book_id):
    old = table().delete_item(Key={"id": book_id}, ReturnValues="ALL_OLD").get("Attributes")
    return bool(old)  # немає запису -> Attributes відсутній або порожній


def handle(method, path, body=""):
    """Бізнес-логіка без прив'язки до Lambda: повертає (status, payload)."""
    match = ROUTE.search(path or "")
    if not match:
        return 404, {"error": "not found"}
    resource, book_id = match.groups()
    method = (method or "GET").upper()

    if resource == "health":
        return 200, {"status": "ok", "instance": INSTANCE_ID}

    if book_id is None:
        if method == "GET":
            return 200, list_books()
        if method == "POST":
            try:
                data = json.loads(body or "{}")
            except json.JSONDecodeError:
                return 400, {"error": "invalid JSON"}
            book, error = validate_book(data)
            if error:
                return 400, {"error": error}
            return 201, create_book(book)
        return 405, {"error": "method not allowed"}

    if method == "GET":
        book = get_book(book_id)
        return (200, book) if book else (404, {"error": "not found"})
    if method == "DELETE":
        return (204, None) if delete_book(book_id) else (404, {"error": "not found"})
    return 405, {"error": "method not allowed"}


def http_response(status, payload):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json; charset=utf-8", "X-Instance": INSTANCE_ID},
        "body": "" if payload is None else json.dumps(payload, ensure_ascii=False),
    }


def lambda_handler(event, context):
    """Точка входу Lambda для API Gateway REST API (AWS_PROXY)."""
    body = event.get("body") or ""
    if event.get("isBase64Encoded") and body:
        body = base64.b64decode(body).decode("utf-8")
    body = body.lstrip("\ufeff")  # Windows PowerShell 5.1 може додати BOM до тіла запиту
    try:
        status, payload = handle(event.get("httpMethod"), event.get("path"), body)
    except Exception as exc:  # noqa: BLE001 — будь-яка помилка БД -> 500 у JSON
        print(json.dumps({"level": "error", "msg": "unhandled", "error": str(exc)}))
        status, payload = 500, {"error": "internal server error"}
    print(
        json.dumps(
            {"level": "info", "method": event.get("httpMethod"), "path": event.get("path"), "status": status}
        )
    )
    return http_response(status, payload)
