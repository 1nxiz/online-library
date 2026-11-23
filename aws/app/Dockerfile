# ЛР-9: контейнерна версія Lambda-застосунку з ЛР-8 (той самий handler.py).
# ЛР-10: + metrics.py — публікація метрик у CloudWatch.
# Збирається з контексту aws/:  docker build -f app/Dockerfile .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY lambda/handler.py app/server.py app/metrics.py ./

RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 8000
CMD ["python", "server.py"]
