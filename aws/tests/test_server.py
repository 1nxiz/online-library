import json
import os
import sys
import threading
import urllib.error
import urllib.request

import boto3
import pytest
from moto import mock_aws

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "lambda"))
sys.path.insert(0, os.path.join(HERE, "..", "app"))
import handler  # noqa: E402
import server  # noqa: E402


@pytest.fixture
def running_server(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)
    monkeypatch.setattr(handler, "INSTANCE_ID", "app2")
    with mock_aws():
        handler._table = None
        assert server.ensure_table(retries=3, delay=0)
        srv = server.make_server(port=0)
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        yield f"http://127.0.0.1:{srv.server_address[1]}"
        srv.shutdown()
        handler._table = None


def request(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw = resp.read()
            return resp.status, resp.headers, json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        raw = err.read()
        return err.code, err.headers, json.loads(raw) if raw else None


def test_health_has_instance(running_server):
    status, headers, body = request("GET", f"{running_server}/health")
    assert status == 200
    assert body == {"status": "ok", "instance": "app2"}
    assert headers["X-Instance"] == "app2"
    assert "charset=utf-8" in headers["Content-Type"]


def test_crud_over_http(running_server):
    status, _, created = request("POST", f"{running_server}/books", {"title": "Кобзар", "author": "Шевченко"})
    assert status == 201
    status, _, books = request("GET", f"{running_server}/books?ignored=1")
    assert status == 200 and books[0]["title"] == "Кобзар"
    assert request("DELETE", f"{running_server}/books/{created['id']}")[0] == 204
    assert request("GET", f"{running_server}/books/{created['id']}")[0] == 404


def test_errors(running_server):
    assert request("POST", f"{running_server}/books", {"title": ""})[0] == 400
    assert request("GET", f"{running_server}/nope")[0] == 404


def test_ensure_table_is_idempotent(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)
    with mock_aws():
        assert server.ensure_table(retries=3, delay=0)
        assert server.ensure_table(retries=3, delay=0)
        names = boto3.client("dynamodb").list_tables()["TableNames"]
        assert names == ["Books"]


def test_fail_rate_and_delay_skip_health(running_server, monkeypatch):
    monkeypatch.setattr(server, "FAIL_RATE", 1.0)
    monkeypatch.setattr(server, "DELAY_MS", 0)
    status, _, body = request("GET", f"{running_server}/books")
    assert status == 500 and body == {"error": "injected failure"}
    assert request("GET", f"{running_server}/health")[0] == 200


def test_requests_are_recorded_in_metrics(running_server, monkeypatch):
    recorded = []

    class Recorder:
        def record(self, status, ms):
            recorded.append((status, ms))

    monkeypatch.setattr(server, "metrics", Recorder())
    monkeypatch.setattr(server, "DELAY_MS", 30)
    request("GET", f"{running_server}/books")
    request("GET", f"{running_server}/health")  # службовий шлях не рахується
    assert len(recorded) == 1
    assert recorded[0][0] == 200 and recorded[0][1] >= 30
