FROM python:3.12-slim

# версія застосунку «зашивається» в образ під час збірки (CI передає git-тег або SHA)
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# спочатку залежності, щоб Docker кешував цей шар
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# запуск не від root
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 5000

# --preload: БД ініціалізується один раз, а не в кожному воркері
CMD ["gunicorn", "--preload", "-w", "2", "-b", "0.0.0.0:5000", "app:create_app()"]
