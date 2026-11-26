import pytest

import app as app_module


@pytest.fixture
def client():
    app_module.app.config["TESTING"] = True
    return app_module.app.test_client()


BOOK = {"id": 1, "title": "Кобзар", "author": "Тарас Шевченко", "year": 1840, "available": True}


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"
    assert resp.get_json()["pod"]


def test_version(client, monkeypatch):
    monkeypatch.setattr(app_module, "APP_VERSION", "1.2.3")
    assert client.get("/version").get_json() == {"version": "1.2.3"}
    assert client.get("/api/version").get_json() == {"version": "1.2.3"}


def test_info(client, monkeypatch):
    monkeypatch.setattr(app_module, "APP_TITLE", "Моя бібліотека")
    assert client.get("/api/info").get_json()["title"] == "Моя бібліотека"


def test_get_books(client, monkeypatch):
    monkeypatch.setattr(app_module, "list_books", lambda q="": [BOOK])
    resp = client.get("/api/books")
    assert resp.status_code == 200
    assert resp.get_json()[0]["author"] == "Тарас Шевченко"


def test_search_passes_query(client, monkeypatch):
    seen = {}

    def fake(q=""):
        seen["q"] = q
        return []

    monkeypatch.setattr(app_module, "list_books", fake)
    client.get("/api/books?q=  Кобзар ")
    assert seen["q"] == "Кобзар"


def test_create_book(client, monkeypatch):
    monkeypatch.setattr(
        app_module,
        "add_book",
        lambda t, a, y: {"id": 2, "title": t, "author": a, "year": y, "available": True},
    )
    resp = client.post(
        "/api/books",
        json={"title": "Тіні забутих предків", "author": "Михайло Коцюбинський", "year": "1911"},
    )
    assert resp.status_code == 201
    assert resp.get_json()["year"] == 1911


@pytest.mark.parametrize(
    "payload",
    [
        {"title": "   ", "author": "X"},
        {"title": "X", "author": ""},
        {"title": "X", "author": "Y", "year": "abc"},
        {"title": "X", "author": "Y", "year": 3000},
    ],
)
def test_create_book_invalid(client, payload):
    assert client.post("/api/books", json=payload).status_code == 400


def test_borrow_and_return(client, monkeypatch):
    monkeypatch.setattr(app_module, "set_available", lambda i, a: {**BOOK, "available": a})
    assert client.post("/api/books/1/borrow").get_json()["available"] is False
    assert client.post("/api/books/1/return").get_json()["available"] is True


def test_borrow_not_found(client, monkeypatch):
    monkeypatch.setattr(app_module, "set_available", lambda i, a: None)
    assert client.post("/api/books/99/borrow").status_code == 404


def test_delete_book(client, monkeypatch):
    monkeypatch.setattr(app_module, "delete_book", lambda i: True)
    assert client.delete("/api/books/1").status_code == 204
    monkeypatch.setattr(app_module, "delete_book", lambda i: False)
    assert client.delete("/api/books/1").status_code == 404


def test_database_url_from_parts(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("DB_USER", "lib")
    monkeypatch.setenv("DB_PASSWORD", "secret")
    monkeypatch.setenv("DB_HOST", "db")
    monkeypatch.setenv("DB_NAME", "library")
    assert app_module.database_url() == "postgresql://lib:secret@db:5432/library"


# ---------------- ЛР-7: метрики, JSON-логи, FAIL_RATE ----------------


def metric_value(client, name, **labels):
    """Значення метрики з тексту /metrics (0, якщо рядка ще немає)."""
    text = client.get("/metrics").get_data(as_text=True)
    want = ",".join(f'{k}="{v}"' for k, v in labels.items())
    for line in text.splitlines():
        if line.startswith(f"{name}{{") and all(p in line for p in want.split(",")):
            return float(line.rsplit(" ", 1)[1])
    return 0.0


def test_metrics_endpoint(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "text/plain" in resp.content_type
    assert "http_requests_total" in resp.get_data(as_text=True)


def test_requests_are_counted_by_route_template(client, monkeypatch):
    monkeypatch.setattr(app_module, "set_available", lambda i, a: {**BOOK, "available": a})
    labels = {"method": "POST", "route": "/api/books/<int:book_id>/borrow", "status": "200"}
    before = metric_value(client, "http_requests_total", **labels)
    client.post("/api/books/7/borrow")
    client.post("/api/books/8/borrow")
    # мітка — шаблон маршруту, а не /api/books/7/borrow: кардинальність не росте з кількістю id
    assert metric_value(client, "http_requests_total", **labels) == before + 2
    assert 'route="/api/books/7/borrow"' not in client.get("/metrics").get_data(as_text=True)


def test_latency_histogram(client, monkeypatch):
    monkeypatch.setattr(app_module, "list_books", lambda q="": [])
    client.get("/api/books")
    count = metric_value(
        client, "http_request_duration_seconds_count", method="GET", route="/api/books"
    )
    assert count >= 1


def test_health_and_metrics_are_not_counted(client):
    before = metric_value(client, "http_requests_total", route="/health")
    client.get("/health")
    assert metric_value(client, "http_requests_total", route="/health") == before == 0


def test_fail_rate_injects_500(client, monkeypatch):
    monkeypatch.setattr(app_module, "FAIL_RATE", 1.0)
    monkeypatch.setattr(app_module, "list_books", lambda q="": [])
    assert client.get("/api/books").status_code == 500
    # проби і метрики не ламаються, інакше Kubernetes перезапускав би поди
    assert client.get("/health").status_code == 200
    assert client.get("/metrics").status_code == 200


def test_fail_rate_zero_by_default(client, monkeypatch):
    monkeypatch.setattr(app_module, "list_books", lambda q="": [])
    assert all(client.get("/api/books").status_code == 200 for _ in range(20))


def test_unhandled_error_returns_json_500(client, monkeypatch):
    def boom(q=""):
        raise RuntimeError("db is down")

    monkeypatch.setattr(app_module, "list_books", boom)
    resp = client.get("/api/books")
    assert resp.status_code == 500
    assert resp.get_json() == {"error": "internal server error"}


def test_request_log_fields(client, monkeypatch, caplog):
    monkeypatch.setattr(app_module, "list_books", lambda q="": [])
    with caplog.at_level("INFO", logger="library"):
        client.get("/api/books")
    record = [r for r in caplog.records if r.getMessage() == "request"][-1]
    assert record.fields["method"] == "GET"
    assert record.fields["route"] == "/api/books"
    assert record.fields["status"] == 200
    assert record.fields["duration_ms"] >= 0


def test_json_formatter():
    import json
    import logging

    record = logging.LogRecord("library", logging.ERROR, __file__, 1, "request", None, None)
    record.fields = {"method": "GET", "route": "/api/books", "status": 500, "duration_ms": 1.5}
    line = json.loads(app_module.JsonFormatter().format(record))
    assert line["level"] == "error"
    assert line["msg"] == "request"
    assert line["status"] == 500
    assert {"time", "version", "method", "route", "duration_ms"} <= line.keys()
