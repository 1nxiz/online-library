"""Онлайн бібліотека — REST API на Flask + PostgreSQL."""
import sys

import logging
import os
import socket
import time

import psycopg2
from flask import Flask, jsonify, request
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
app.json.ensure_ascii = False  # кирилиця в JSON без \uXXXX

# --- конфігурація (у Kubernetes приходить з ConfigMap / Secret) ---
APP_VERSION = os.getenv("APP_VERSION", "dev")
APP_TITLE = os.getenv("APP_TITLE", "Онлайн бібліотека")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")

logging.basicConfig(level=LOG_LEVEL)
log = logging.getLogger("library")


def database_url():
    """DATABASE_URL має пріоритет; інакше URL збирається з окремих змінних."""
    url = os.getenv("DATABASE_URL")
    if url:
        return url
    user = os.getenv("DB_USER", "postgres")
    password = os.getenv("DB_PASSWORD", "postgres")
    host = os.getenv("DB_HOST", "localhost")
    port = os.getenv("DB_PORT", "5432")
    name = os.getenv("DB_NAME", "library")
    return f"postgresql://{user}:{password}@{host}:{port}/{name}"


def run_query(query, params=None, fetch=None):
    """Виконує SQL-запит. fetch: None | 'one' | 'all'."""
    conn = psycopg2.connect(database_url())
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, params)
            result = None
            if fetch == "one":
                result = cur.fetchone()
            elif fetch == "all":
                result = cur.fetchall()
        conn.commit()
        return result
    finally:
        conn.close()


def init_db(retries=15):
    """Створює таблицю книг; чекає, поки БД стане доступною."""
    for _ in range(retries):
        try:
            run_query(
                """CREATE TABLE IF NOT EXISTS books (
                       id SERIAL PRIMARY KEY,
                       title VARCHAR(200) NOT NULL,
                       author VARCHAR(200) NOT NULL,
                       year INTEGER,
                       available BOOLEAN NOT NULL DEFAULT TRUE
                   )"""
            )
            log.info("Database is ready")
            return
        except psycopg2.OperationalError:
            log.warning("Database is not ready, retrying...")
            time.sleep(2)
    raise RuntimeError("Database is not available")


# --- функції роботи з БД (у тестах їх підміняємо) ---
def list_books(query=""):
    if query:
        pattern = f"%{query}%"
        return run_query(
            "SELECT id, title, author, year, available FROM books "
            "WHERE title ILIKE %s OR author ILIKE %s ORDER BY id",
            (pattern, pattern),
            fetch="all",
        )
    return run_query(
        "SELECT id, title, author, year, available FROM books ORDER BY id",
        fetch="all",
    )


def add_book(title, author, year):
    return run_query(
        "INSERT INTO books (title, author, year) VALUES (%s, %s, %s) "
        "RETURNING id, title, author, year, available",
        (title, author, year),
        fetch="one",
    )


def set_available(book_id, available):
    return run_query(
        "UPDATE books SET available = %s WHERE id = %s "
        "RETURNING id, title, author, year, available",
        (available, book_id),
        fetch="one",
    )


def delete_book(book_id):
    row = run_query("DELETE FROM books WHERE id = %s RETURNING id", (book_id,), fetch="one")
    return row is not None


def validate_book(data):
    """Повертає (book, error). book — очищені поля."""
    title = (data.get("title") or "").strip()
    author = (data.get("author") or "").strip()
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


# --- службові маршрути ---
@app.route("/health")
def health():
    # pod — ім'я контейнера/пода: видно, яка репліка відповіла
    return jsonify(status="ok", version=APP_VERSION, pod=socket.gethostname())


@app.route("/version")
@app.route("/api/version")
def version():
    return jsonify(version=APP_VERSION)


@app.route("/api/info")
def info():
    return jsonify(title=APP_TITLE, version=APP_VERSION)


# --- книги ---
@app.route("/api/books", methods=["GET"])
def get_books():
    query = (request.args.get("q") or "").strip()
    return jsonify(list_books(query))


@app.route("/api/books", methods=["POST"])
def create_book():
    book, error = validate_book(request.get_json(silent=True) or {})
    if error:
        return jsonify(error=error), 400
    return jsonify(add_book(book["title"], book["author"], book["year"])), 201


@app.route("/api/books/<int:book_id>/borrow", methods=["POST"])
def borrow_book(book_id):
    book = set_available(book_id, False)
    if book is None:
        return jsonify(error="not found"), 404
    return jsonify(book)


@app.route("/api/books/<int:book_id>/return", methods=["POST"])
def return_book(book_id):
    book = set_available(book_id, True)
    if book is None:
        return jsonify(error="not found"), 404
    return jsonify(book)


@app.route("/api/books/<int:book_id>", methods=["DELETE"])
def remove_book(book_id):
    if delete_book(book_id):
        return "", 204
    return jsonify(error="not found"), 404


def create_app():
    init_db()
    return app


if __name__ == "__main__":
    create_app().run(host="0.0.0.0", port=5000)
