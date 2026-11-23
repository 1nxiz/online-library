"""ЛР-10: аналіз метрик «Онлайн бібліотеки» в Amazon CloudWatch (LocalStack).

Читає метрики, які застосунок публікує через PutMetricData:
  * GetMetricData       — часові ряди з кроком --period (Requests Sum, Errors Sum, Latency Average/Maximum);
  * GetMetricStatistics — підсумки за все вікно спостереження;
обчислює кількість запитів за інтервал, запити за секунду, частку помилок і середній час відповіді,
підсумовує їх по фазах експерименту (out/phases.json), показує стан та історію Alarm
і будує графіки (out/lab10-metrics.png).

Запуск: docker compose -f aws/docker-compose.yml run --rm analyze --minutes 30
"""

import argparse
import csv
import json
import os
from datetime import UTC, datetime, timedelta

import boto3
import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

NAMESPACE = os.environ.get("METRICS_NAMESPACE", "OnlineLibrary")
DIMENSIONS = [{"Name": "Service", "Value": os.environ.get("METRICS_SERVICE", "online-library")}]
ALARMS = ["library-high-errors", "library-high-latency"]
PHASE_COLORS = {"normal": "#d8ecd8", "errors": "#f6d5d5", "latency": "#f6e7c8", "recovery": "#d6e4f3"}
PHASE_NAMES = {
    "normal": "звичайне навантаження",
    "errors": "помилки (FAIL_RATE)",
    "latency": "затримки (DELAY_MS)",
    "recovery": "відновлення",
}


def cw_client():
    return boto3.client("cloudwatch", endpoint_url=os.environ.get("AWS_ENDPOINT_URL") or None)


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def metric_query(qid, name, stat, period):
    return {
        "Id": qid,
        "MetricStat": {
            "Metric": {"Namespace": NAMESPACE, "MetricName": name, "Dimensions": DIMENSIONS},
            "Period": period,
            "Stat": stat,
        },
        "ReturnData": True,
    }


def fetch_series(cw, start, end, period):
    """GetMetricData -> список рядків по інтервалах."""
    queries = [
        metric_query("req", "Requests", "Sum", period),
        metric_query("err", "Errors", "Sum", period),
        metric_query("lat", "Latency", "Average", period),
        metric_query("latmax", "Latency", "Maximum", period),
    ]
    series = {q["Id"]: {} for q in queries}
    kwargs = {
        "MetricDataQueries": queries,
        "StartTime": start,
        "EndTime": end,
        "ScanBy": "TimestampAscending",
    }
    while True:
        resp = cw.get_metric_data(**kwargs)
        for result in resp["MetricDataResults"]:
            for ts, value in zip(result["Timestamps"], result["Values"], strict=False):
                series[result["Id"]][ts.astimezone(UTC)] = value
        if not resp.get("NextToken"):
            break
        kwargs["NextToken"] = resp["NextToken"]

    rows = []
    for ts in sorted(set(series["req"]) | set(series["err"])):
        req = series["req"].get(ts, 0.0)
        err = series["err"].get(ts, 0.0)
        rows.append(
            {
                "time": ts,
                "requests": int(round(req)),
                "errors": int(round(err)),
                "rps": round(req / period, 2),
                "error_rate": round(err / req, 4) if req else 0.0,
                "latency_avg": round(series["lat"].get(ts, 0.0), 1),
                "latency_max": round(series["latmax"].get(ts, 0.0), 1),
            }
        )
    return rows


def totals_via_statistics(cw, start, end):
    """GetMetricStatistics: одна точка на все вікно."""
    period = max(60, int((end - start).total_seconds()) // 60 * 60)

    def one(name, stat):
        resp = cw.get_metric_statistics(
            Namespace=NAMESPACE,
            MetricName=name,
            Dimensions=DIMENSIONS,
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=[stat],
        )
        points = resp["Datapoints"]
        if not points:
            return 0.0
        if stat == "Sum":
            return sum(p["Sum"] for p in points)
        weights = [p.get("SampleCount", 1) for p in points]
        total = sum(weights) or 1
        return sum(p["Average"] * w for p, w in zip(points, weights, strict=False)) / total

    requests = one("Requests", "Sum")
    errors = one("Errors", "Sum")
    return {
        "requests": int(round(requests)),
        "errors": int(round(errors)),
        "error_rate": errors / requests if requests else 0.0,
        "latency_avg": one("Latency", "Average"),
    }


def summarize(rows):
    req = sum(r["requests"] for r in rows)
    err = sum(r["errors"] for r in rows)
    lat = sum(r["latency_avg"] * r["requests"] for r in rows) / req if req else 0.0
    seconds = len(rows) * 60 if rows else 0
    return {
        "requests": req,
        "errors": err,
        "error_rate": err / req if req else 0.0,
        "latency_avg": lat,
        "rps": req / seconds if seconds else 0.0,
    }


def phase_summaries(rows, phases, period):
    result = []
    for ph in phases:
        start, end = parse_time(ph["start"]), parse_time(ph["end"])
        # інтервал належить фазі, якщо його середина всередині фази
        inside = [r for r in rows if start <= r["time"] + timedelta(seconds=period / 2) < end]
        s = summarize(inside)
        s["rps"] = s["requests"] / max(1.0, (end - start).total_seconds())
        result.append({"phase": ph["name"], **s})
    return result


def alarm_info(cw):
    states, history = [], []
    try:
        alarms = cw.describe_alarms(AlarmNames=ALARMS)["MetricAlarms"]
    except Exception as exc:  # noqa: BLE001
        print(f"Не вдалося прочитати Alarm: {exc}")
        return states, history
    for alarm in alarms:
        states.append(
            {
                "name": alarm["AlarmName"],
                "state": alarm["StateValue"],
                "metric": f"{alarm['MetricName']} {alarm['Statistic']}",
                "threshold": alarm["Threshold"],
                "operator": alarm["ComparisonOperator"],
            }
        )
        try:
            items = cw.describe_alarm_history(AlarmName=alarm["AlarmName"], HistoryItemType="StateUpdate")
        except Exception as exc:  # noqa: BLE001
            print(f"Історія {alarm['AlarmName']} недоступна: {exc}")
            continue
        for item in items.get("AlarmHistoryItems", []):
            data = json.loads(item.get("HistoryData") or "{}")
            summary = item.get("HistorySummary", "")
            new_state = data.get("newState", {}).get("stateValue") or summary.rsplit(" ", 1)[-1]
            history.append(
                {
                    "time": item["Timestamp"].astimezone(UTC),
                    "alarm": item["AlarmName"],
                    "new_state": new_state,
                    "summary": summary,
                }
            )
    history.sort(key=lambda h: h["time"])
    return states, history


def plot(rows, phases, history, thresholds, path, period=60):
    if not rows:
        print("Немає даних для графіка")
        return
    # точка інтервалу малюється посередині хвилини, яку вона описує
    times = [r["time"] + timedelta(seconds=period / 2) for r in rows]
    width = timedelta(seconds=period * 0.8)
    fig, axes = plt.subplots(3, 1, figsize=(13, 10), sharex=True)
    fig.suptitle("Онлайн бібліотека — метрики CloudWatch (LocalStack)", fontsize=14, fontweight="bold")

    ax = axes[0]
    ax.bar(times, [r["requests"] for r in rows], width=width, color="#3b6ea5")
    ax.set_ylabel("Запитів за хвилину")
    ax.set_title("Кількість оброблених запитів (Requests, Sum)", loc="left", fontsize=10, pad=16)

    ax = axes[1]
    ax.bar(times, [r["errors"] for r in rows], width=width, color="#c0392b", label="Errors (Sum)")
    ax.axhline(
        thresholds["errors"],
        color="#c0392b",
        linestyle="--",
        linewidth=1,
        label=f"поріг Alarm: > {thresholds['errors']:g}",
    )
    ax.set_ylabel("Помилок 5xx за хвилину")
    ax.set_title("Помилки та частка помилок", loc="left", fontsize=10)
    twin = ax.twinx()
    twin.plot(
        times,
        [r["error_rate"] * 100 for r in rows],
        color="#7f1d1d",
        marker="o",
        markersize=3,
        label="частка помилок, %",
    )
    twin.set_ylabel("Частка помилок, %")
    twin.set_ylim(bottom=0)
    lines = ax.get_legend_handles_labels()
    lines2 = twin.get_legend_handles_labels()
    ax.legend(lines[0] + lines2[0], lines[1] + lines2[1], loc="upper left", fontsize=8)

    ax = axes[2]
    ax.plot(
        times,
        [r["latency_avg"] for r in rows],
        color="#b7791f",
        marker="o",
        markersize=3,
        label="середній час (Average)",
    )
    ax.plot(times, [r["latency_max"] for r in rows], color="#b7791f", alpha=0.35, label="максимум (Maximum)")
    ax.axhline(
        thresholds["latency"],
        color="#b7791f",
        linestyle="--",
        linewidth=1,
        label=f"поріг Alarm: > {thresholds['latency']:g} мс",
    )
    ax.set_ylabel("Час відповіді, мс")
    ax.set_title("Тривалість обробки запиту (Latency)", loc="left", fontsize=10)
    ax.legend(loc="upper left", fontsize=8)

    for ph in phases:
        start, end = parse_time(ph["start"]), parse_time(ph["end"])
        color = PHASE_COLORS.get(ph["name"], "#eeeeee")
        for a in axes:
            a.axvspan(start, end, color=color, alpha=0.6, zorder=0)
        axes[0].text(
            start + (end - start) / 2,
            1.0,
            PHASE_NAMES.get(ph["name"], ph["name"]),
            transform=axes[0].get_xaxis_transform(),
            ha="center",
            va="bottom",
            fontsize=8,
        )

    for h in history:
        color = "#c0392b" if h["new_state"] == "ALARM" else "#2f855a"
        target = axes[1] if "errors" in h["alarm"] else axes[2]
        target.axvline(h["time"], color=color, linestyle=":", linewidth=1.5)
        target.text(
            h["time"],
            0.95,
            f" {h['new_state']}",
            transform=target.get_xaxis_transform(),
            color=color,
            fontsize=8,
            va="top",
        )

    axes[-1].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=UTC))
    axes[-1].set_xlabel("Час (UTC)")
    for a in axes:
        a.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    print(f"Графік збережено: {path}")


def fmt_table(headers, rows):
    widths = [
        max(len(str(h)), *(len(str(r[i])) for r in rows)) if rows else len(str(h))
        for i, h in enumerate(headers)
    ]
    line = "  ".join(str(h).ljust(w) for h, w in zip(headers, widths, strict=False))
    out = [line, "  ".join("-" * w for w in widths)]
    out += ["  ".join(str(v).ljust(w) for v, w in zip(r, widths, strict=False)) for r in rows]
    return "\n".join(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minutes", type=int, default=30, help="вікно спостереження, хв")
    parser.add_argument("--period", type=int, default=60, help="крок агрегації, с")
    parser.add_argument("--out", default="/out")
    parser.add_argument("--error-threshold", type=float, default=10)
    parser.add_argument("--latency-threshold", type=float, default=300)
    args = parser.parse_args(argv)

    cw = cw_client()
    end = datetime.now(UTC)
    start = end - timedelta(minutes=args.minutes)
    os.makedirs(args.out, exist_ok=True)
    phases_path = os.path.join(args.out, "phases.json")
    phases = json.load(open(phases_path, encoding="utf-8-sig")) if os.path.exists(phases_path) else []
    if phases:
        start = min(start, parse_time(phases[0]["start"]) - timedelta(minutes=1))
    # інтервали вирівнюються по межі хвилини (як у консолі CloudWatch)
    start = start.replace(second=0, microsecond=0)
    end = (end + timedelta(minutes=1)).replace(second=0, microsecond=0)

    rows = fetch_series(cw, start, end, args.period)
    print(f"GetMetricData: {len(rows)} інтервалів по {args.period} с, {start:%H:%M}–{end:%H:%M} UTC\n")
    print(
        fmt_table(
            ["Час UTC", "Запитів", "Запит/с", "Помилок", "Частка помилок", "Сер. час, мс", "Макс., мс"],
            [
                [
                    f"{r['time']:%H:%M}",
                    r["requests"],
                    r["rps"],
                    r["errors"],
                    f"{r['error_rate']:.1%}",
                    r["latency_avg"],
                    r["latency_max"],
                ]
                for r in rows
            ],
        )
    )

    totals = totals_via_statistics(cw, start, end)
    print("\nGetMetricStatistics за все вікно:")
    print(
        f"  запитів: {totals['requests']}, помилок: {totals['errors']}, "
        f"частка помилок: {totals['error_rate']:.2%}, середній час: {totals['latency_avg']:.1f} мс"
    )

    summaries = phase_summaries(rows, phases, args.period) if phases else []
    if summaries:
        print("\nПідсумки по фазах експерименту:")
        print(
            fmt_table(
                ["Фаза", "Запитів", "Запит/с", "Помилок", "Частка помилок", "Сер. час, мс"],
                [
                    [
                        PHASE_NAMES.get(s["phase"], s["phase"]),
                        s["requests"],
                        f"{s['rps']:.1f}",
                        s["errors"],
                        f"{s['error_rate']:.1%}",
                        f"{s['latency_avg']:.1f}",
                    ]
                    for s in summaries
                ],
            )
        )

    states, history = alarm_info(cw)
    if states:
        print("\nAlarm (поточний стан):")
        print(
            fmt_table(
                ["Alarm", "Метрика", "Умова", "Стан"],
                [[s["name"], s["metric"], f"{s['operator']} {s['threshold']:g}", s["state"]] for s in states],
            )
        )
    if history:
        print("\nІсторія переходів Alarm:")
        print(
            fmt_table(
                ["Час UTC", "Alarm", "Новий стан"],
                [[f"{h['time']:%H:%M:%S}", h["alarm"], h["new_state"]] for h in history],
            )
        )

    with open(os.path.join(args.out, "lab10-metrics.csv"), "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["time_utc", "requests", "rps", "errors", "error_rate", "latency_avg_ms", "latency_max_ms"]
        )
        for r in rows:
            writer.writerow(
                [
                    r["time"].isoformat(),
                    r["requests"],
                    r["rps"],
                    r["errors"],
                    r["error_rate"],
                    r["latency_avg"],
                    r["latency_max"],
                ]
            )
    with open(os.path.join(args.out, "lab10-summary.json"), "w", encoding="utf-8") as f:
        json.dump(
            {
                "totals": totals,
                "phases": summaries,
                "alarms": states,
                "history": [{**h, "time": h["time"].isoformat()} for h in history],
            },
            f,
            ensure_ascii=False,
            indent=2,
        )
    plot(
        rows,
        phases,
        history,
        {"errors": args.error_threshold, "latency": args.latency_threshold},
        os.path.join(args.out, "lab10-metrics.png"),
        args.period,
    )
    return rows, totals, summaries, states, history


if __name__ == "__main__":
    main()
