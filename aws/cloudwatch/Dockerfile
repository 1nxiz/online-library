# ЛР-10: утиліта аналізу метрик CloudWatch (GetMetricData / GetMetricStatistics + графік).
# Збирається з контексту aws/:  docker build -f cloudwatch/Dockerfile .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MPLCONFIGDIR=/tmp/matplotlib

RUN pip install --no-cache-dir boto3==1.40.76 matplotlib==3.10.7

WORKDIR /tool
COPY cloudwatch/analyze.py .

ENTRYPOINT ["python", "analyze.py"]
