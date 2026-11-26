"""Онлайн бібліотека — REST API на Flask + PostgreSQL."""

import json
import logging
import os
import random
import socket
import sys
import time
from datetime import UTC, datetime

import psycopg2
from flask import Flask, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from psycopg2.extras import RealDictCursor
from werkzeug.exceptions import HTTPException

app = Flask(__name__)
app.json.ensure_ascii = False  # кирилиця в JSON без \uXXXX

# --- конфігурація (у Kubernetes приходить з ConfigMap / Secret) ---
APP_VERSION = os.getenv("APP_VERSION", "dev")
APP_TITLE = os.getenv("APP_TITLE", "Онлайн бібліотека")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")

# ЛР-7: частка запитів, які навмисно отримують 500 («погана» версія для демонстрації відкату)
FAIL_RATE = float(os.getenv("FAIL_RATE", "0"))


# --- ЛР-7: логи у JSON, один об'єкт на рядок у stdout ---
class JsonFormatter(logging.Formatter):
    """Перетворює запис логу на JSON: час, рівень, повідомлення + додаткові поля."""

    def format(self, record):
        entry = {
            "time": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "msg": record.getMessage(),
            "logger": record.name,
            "version": APP_VERSION,
        }
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False)


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
logging.basicConfig(level=LOG_LEVEL, handlers=[_handler], force=True)
log = logging.getLogger("library")

# --- ЛР-7: метрики Prometheus ---
# мітки лише з малою кардинальністю: метод, ШАБЛОН маршруту (не URL з id), статус
REQUESTS = Counter("http_requests_total", "Кількість HTTP-запитів", ["method", "route", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds", "Тривалість обробки HTTP-запиту", ["method", "route"]
)
# службові шляхи не рахуємо і не ламаємо: їх смикають Prometheus і проби Kubernetes
SKIP_PATHS = {"/metrics", "/health"}


@app.before_request
def start_timer():
    g.start = time.perf_counter()
    if request.path not in SKIP_PATHS and random.random() < FAIL_RATE:
        return jsonify(error="injected failure"), 500
    return None


@app.after_request
def record_request(response):
    if request.path in SKIP_PATHS:
        return response
    route = request.url_rule.rule if request.url_rule else "unknown"
    duration = time.perf_counter() - g.get("start", time.perf_counter())
    status = response.status_code
    REQUESTS.labels(request.method, route, str(status)).inc()
    LATENCY.labels(request.method, route).observe(duration)
    log.log(
        logging.ERROR if status >= 500 else logging.INFO,
        "request",
        extra={
            "fields": {
                "method": request.method,
                "route": route,
                "status": status,
                "duration_ms": round(duration * 1000, 1),
            }
        },
    )
    return response


@app.errorhandler(Exception)
def handle_error(error):
    """Необроблена помилка -> 500 у JSON (і вона теж потрапить у метрики та логи)."""
    if isinstance(error, HTTPException):
        return error
    log.exception("unhandled error")
    return jsonify(error="internal server error"), 500


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


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
