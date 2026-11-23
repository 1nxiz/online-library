import json
import os
import sys

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))
import handler  # noqa: E402


@pytest.fixture
def books_table(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)
    with mock_aws():
        boto3.client("dynamodb").create_table(
            TableName="Books",
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        handler._table = None
        yield
        handler._table = None


def event(method, path, body=None):
    return {"httpMethod": method, "path": path, "body": None if body is None else json.dumps(body)}


def call(method, path, body=None):
    resp = handler.lambda_handler(event(method, path, body), None)
    payload = json.loads(resp["body"]) if resp["body"] else None
    return resp["statusCode"], payload, resp["headers"]


def test_health(books_table):
    status, payload, headers = call("GET", "/health")
    assert status == 200 and payload["status"] == "ok"
    assert headers["X-Instance"] == handler.INSTANCE_ID


def test_crud_cycle(books_table):
    status, created, _ = call("POST", "/books", {"title": "Кобзар", "author": "Шевченко", "year": "1840"})
    assert status == 201
    assert created["year"] == 1840 and created["available"] is True
    book_id = created["id"]

    status, books, _ = call("GET", "/books")
    assert status == 200 and [b["id"] for b in books] == [book_id]

    status, one, _ = call("GET", f"/books/{book_id}")
    assert status == 200 and one["title"] == "Кобзар"
    assert isinstance(one["year"], int)  # Decimal -> int

    assert call("DELETE", f"/books/{book_id}")[0] == 204
    assert call("GET", f"/books/{book_id}")[0] == 404
    assert call("DELETE", f"/books/{book_id}")[0] == 404


def test_stage_prefix_in_path(books_table):
    assert call("GET", "/dev/books")[0] == 200
    assert call("GET", "/restapis/abc/dev/_user_request_/health")[0] == 200


@pytest.mark.parametrize(
    "body",
    [
        {"title": " ", "author": "X"},
        {"title": "X"},
        {"title": "X", "author": "Y", "year": "abc"},
        {"title": "X", "author": "Y", "year": 3000},
        ["not", "an", "object"],
    ],
)
def test_validation(books_table, body):
    assert call("POST", "/books", body)[0] == 400


def test_invalid_json_and_methods(books_table):
    resp = handler.lambda_handler({"httpMethod": "POST", "path": "/books", "body": "{bad"}, None)
    assert resp["statusCode"] == 400
    assert call("PUT", "/books")[0] == 405
    assert call("PATCH", "/books/1")[0] == 405
    assert call("GET", "/unknown")[0] == 404


def test_base64_body(books_table):
    import base64

    raw = json.dumps({"title": "Лісова пісня", "author": "Леся Українка"}).encode()
    ev = {
        "httpMethod": "POST",
        "path": "/books",
        "isBase64Encoded": True,
        "body": base64.b64encode(raw).decode(),
    }
    assert handler.lambda_handler(ev, None)["statusCode"] == 201


def test_db_error_returns_500(monkeypatch):
    def boom():
        raise RuntimeError("dynamodb is down")

    monkeypatch.setattr(handler, "table", boom)
    resp = handler.lambda_handler(event("GET", "/books"), None)
    assert resp["statusCode"] == 500
    assert json.loads(resp["body"]) == {"error": "internal server error"}
