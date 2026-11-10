FROM python:3.12-slim

# версія застосунку «зашивається» в образ під час збірки (CI передає git-тег або SHA)
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# оновлюємо системні пакети базового образу: закриває вразливості, які знаходить Trivy
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# спочатку залежності, щоб Docker кешував цей шар
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# запуск не від root
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 5000

# --preload: БД ініціалізується один раз.
# ЛР-7: один процес з потоками — лічильники Prometheus живуть у пам'яті процесу,
# і з кількома воркерами кожен скрейп бачив би метрики лише одного з них.
CMD ["gunicorn", "--preload", "-w", "1", "--threads", "8", "-b", "0.0.0.0:5000", "app:create_app()"]
