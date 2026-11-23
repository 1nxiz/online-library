import json
import os
import sys
from datetime import UTC, datetime, timedelta

import boto3
import pytest
from moto import mock_aws

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "cloudwatch"))
import analyze  # noqa: E402

DIMS = [{"Name": "Service", "Value": "online-library"}]


def put(cw, ts, requests, errors, latencies):
    data = [
        {"MetricName": "Requests", "Dimensions": DIMS, "Timestamp": ts, "Value": requests, "Unit": "Count"},
        {"MetricName": "Errors", "Dimensions": DIMS, "Timestamp": ts, "Value": errors, "Unit": "Count"},
    ] + [
        {"MetricName": "Latency", "Dimensions": DIMS, "Timestamp": ts, "Value": v, "Unit": "Milliseconds"}
        for v in latencies
    ]
    cw.put_metric_data(Namespace="OnlineLibrary", MetricData=data)


@pytest.fixture
def cw(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)
    with mock_aws():
        yield boto3.client("cloudwatch")


def test_full_analysis(cw, tmp_path):
    base = (datetime.now(UTC) - timedelta(minutes=6)).replace(second=0, microsecond=0)
    # 2 хв норми, 2 хв помилок, 2 хв затримок; кожна хвилина — 6 публікацій по 10 с
    plan = [
        ("normal", 0, 20),
        ("normal", 0, 20),
        ("errors", 30, 20),
        ("errors", 30, 20),
        ("latency", 0, 400),
        ("latency", 0, 400),
    ]
    for minute, (_, err_per_minute, lat) in enumerate(plan):
        for k in range(6):
            ts = base + timedelta(minutes=minute, seconds=5 + k * 10)
            put(cw, ts, 20, err_per_minute / 6, [lat] * 4)
    phases = []
    for i, name in enumerate(["normal", "errors", "latency"]):
        phases.append(
            {
                "name": name,
                "start": (base + timedelta(minutes=2 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "end": (base + timedelta(minutes=2 * i + 2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        )
    (tmp_path / "phases.json").write_text(json.dumps(phases), encoding="utf-8")
    cw.put_metric_alarm(
        AlarmName="library-high-errors",
        Namespace="OnlineLibrary",
        MetricName="Errors",
        Dimensions=DIMS,
        Statistic="Sum",
        Period=60,
        EvaluationPeriods=1,
        Threshold=10,
        ComparisonOperator="GreaterThanThreshold",
    )
    cw.set_alarm_state(AlarmName="library-high-errors", StateValue="ALARM", StateReason="test")

    rows, totals, summaries, states, history = analyze.main(["--minutes", "10", "--out", str(tmp_path)])

    assert len(rows) == 6
    assert all(r["requests"] == 120 for r in rows)
    assert totals["requests"] == 720
    assert totals["errors"] == 60  # 30 помилок/хв × 2 хв
    by_phase = {s["phase"]: s for s in summaries}
    assert by_phase["normal"]["error_rate"] == 0
    assert by_phase["errors"]["error_rate"] == pytest.approx(0.25)
    assert by_phase["latency"]["latency_avg"] == pytest.approx(400)
    assert by_phase["normal"]["rps"] == pytest.approx(2.0)
    assert states[0]["state"] == "ALARM"
    assert (tmp_path / "lab10-metrics.png").stat().st_size > 20_000
    assert (tmp_path / "lab10-metrics.csv").read_text(encoding="utf-8").count("\n") == 7
    assert (
        json.loads((tmp_path / "lab10-summary.json").read_text(encoding="utf-8"))["totals"]["requests"] == 720
    )


def test_empty_window(cw, tmp_path):
    rows, totals, *_ = analyze.main(["--minutes", "5", "--out", str(tmp_path)])
    assert rows == [] and totals["requests"] == 0
