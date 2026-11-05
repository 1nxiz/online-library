import pytest

import app as app_module


@pytest.fixture
def client():
    app_module.app.config["TESTING"] = True
    return app_module.app.test_client()


BOOK = {"id": 1, "title": "Кобзар", "author": "Тарас Шевченко", "year": 1840, "available": True}


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 201
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
