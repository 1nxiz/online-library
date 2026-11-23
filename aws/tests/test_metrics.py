import os
import sys
from datetime import UTC, datetime, timedelta

import boto3
import pytest
from moto import mock_aws

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "lambda"))
sys.path.insert(0, os.path.join(HERE, "..", "app"))
import metrics  # noqa: E402


@pytest.fixture
def cloudwatch(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)
    with mock_aws():
        yield boto3.client("cloudwatch")


def stats(cw, name, stat):
    now = datetime.now(UTC)
    resp = cw.get_metric_statistics(
        Namespace="OnlineLibrary",
        MetricName=name,
        Dimensions=[{"Name": "Service", "Value": "online-library"}],
        StartTime=now - timedelta(minutes=5),
        EndTime=now + timedelta(minutes=1),
        Period=300,
        Statistics=[stat],
    )
    return sum(p[stat] for p in resp["Datapoints"])


def test_flush_publishes_requests_errors_latency(cloudwatch):
    pub = metrics.MetricsPublisher(client=cloudwatch)
    for status, ms in [(200, 10), (200, 30), (500, 50), (201, 10)]:
        pub.record(status, ms)
    sent = pub.flush()
    assert sent == 2 + 4  # Requests, Errors + 4 значення Latency
    assert stats(cloudwatch, "Requests", "Sum") == 4
    assert stats(cloudwatch, "Errors", "Sum") == 1
    assert stats(cloudwatch, "Latency", "Average") == pytest.approx(25.0)
    names = {m["MetricName"] for m in cloudwatch.list_metrics(Namespace="OnlineLibrary")["Metrics"]}
    assert names == {"Requests", "Errors", "Latency"}


def test_flush_resets_buffer_and_skips_empty(cloudwatch):
    pub = metrics.MetricsPublisher(client=cloudwatch)
    assert pub.flush() == 0
    pub.record(200, 5)
    assert pub.flush() == 3
    assert pub.flush() == 0


def test_latency_is_sampled():
    pub = metrics.MetricsPublisher(client=object())
    data = pub.build_metric_data(1000, 3, [1.0] * 1000)
    latency = [d for d in data if d["MetricName"] == "Latency"]
    assert len(latency) == metrics.MAX_LATENCY_SAMPLES
    assert {d["Unit"] for d in data} == {"Count", "Milliseconds"}


def test_batches_of_20(cloudwatch):
    calls = []

    class Spy:
        def put_metric_data(self, **kwargs):
            calls.append(len(kwargs["MetricData"]))

    pub = metrics.MetricsPublisher(client=Spy())
    for _ in range(45):
        pub.record(200, 1)
    pub.flush()
    assert calls == [20, 20, 7]  # 2 лічильники + 45 значень Latency
