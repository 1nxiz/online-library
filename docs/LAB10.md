# Лабораторна робота №10. Моніторинг продуктивності в Amazon CloudWatch (LocalStack)

**Мета:** організувати збір метрик продуктивності «Онлайн бібліотеки» в CloudWatch, обчислити на їх основі показники навантаження, помилок і часу відповіді, налаштувати CloudWatch Alarm і перевірити його спрацювання під час керованого навантаження з штучними помилками та затримками.

## 1. Архітектура

```
   hey (навантаження) ──► nginx :8080 ──► app1 / app2 / app3  (server.py + handler.py)
                                              │  кожен запит: metrics.record(status, ms)
                                              │  раз на 10 с: PutMetricData
                                              ▼
                              ┌──────────── LocalStack ────────────┐
                              │ CloudWatch: простір імен OnlineLibrary, вимір Service=online-library
                              │   Requests (Count)  Errors (Count)  Latency (Milliseconds)
                              │ Alarm: library-high-errors   Errors  Sum     > 10  за 60 с
                              │        library-high-latency  Latency Average > 300 мс за 60 с
                              │ DynamoDB "Books"                    │
                              └──────────────▲─────────────────────┘
                                             │ GetMetricData / GetMetricStatistics / DescribeAlarms
                              aws/cloudwatch/analyze.py ──► out/lab10-metrics.png, .csv, summary.json
```

## 2. Що зроблено

| Файл | Призначення |
|---|---|
| `aws/app/metrics.py` | `MetricsPublisher`: рахує запити, помилки 5xx і тривалість кожного запиту; фоновий потік раз на 10 с надсилає їх через `PutMetricData` (пакетами по 20 точок, до 100 значень Latency за інтервал) |
| `aws/app/server.py` | вимірює тривалість кожного запиту і передає її в `metrics.record()`; змінні `FAIL_RATE` (частка штучних 500) і `DELAY_MS` (штучна затримка) для керованого експерименту; `/health` не рахується і не ламається |
| `aws/cloudwatch/analyze.py` | `GetMetricData` (ряди по хвилинах), `GetMetricStatistics` (підсумок за вікно), обчислення запитів за інтервал, запитів/с, частки помилок і середнього часу; підсумки по фазах; стан та історія Alarm; графік matplotlib |
| `aws/cloudwatch/Dockerfile` | образ утиліти аналізу (boto3 + matplotlib) |
| `aws/docker-compose.yml` | для app1–3 додано `METRICS_ENABLED`, `FAIL_RATE`, `DELAY_MS`; сервіс `analyze` (профіль `tools`) |
| `aws/tests/test_metrics.py`, `test_analyze.py` | тести публікації та аналізу метрик на moto |
| `scripts/lab10.ps1` | покроковий експеримент зі скріншотами |

## 3. Метрики і формули

| Показник | Як отримано |
|---|---|
| Кількість запитів за інтервал | `Requests`, статистика **Sum**, період 60 с |
| Запитів за секунду | Sum(Requests) / 60 |
| Частка помилок | Sum(Errors) / Sum(Requests) |
| Середній час відповіді | `Latency`, статистика **Average** (додатково Maximum) |

## 4. Експеримент

| Фаза | Налаштування | Очікування |
|---|---|---|
| звичайне навантаження | `FAIL_RATE=0`, `DELAY_MS=0` | лише 200, час — одиниці мс, обидва Alarm **OK** |
| помилки | `FAIL_RATE=0.3` | ≈ 30% відповідей 500 → `library-high-errors` = **ALARM** |
| затримки | `DELAY_MS=400` | середній час ≈ 400 мс → `library-high-latency` = **ALARM**, помилки → OK |
| відновлення | `FAIL_RATE=0`, `DELAY_MS=0` | обидва Alarm повертаються в **OK** |

Кожна фаза триває 150 с. Навантаження дає `hey -z 150s -c 5 -q 10 http://nginx/books` (5 клієнтів, до 50 запитів/с). Між фазами екземпляри перестворюються з новими змінними оточення. Час початку і кінця фаз записується в `aws/out/phases.json`, а на графіку фази позначені кольоровими смугами.

## 5. Запуск

```powershell
git checkout lab10
git pull
powershell -ExecutionPolicy Bypass -File scripts\lab10.ps1
```

Вручну:

```powershell
docker compose -f aws/docker-compose.yml up -d --build
$env:FAIL_RATE='0.3'; docker compose -f aws/docker-compose.yml up -d app1 app2 app3   # увімкнути помилки
docker compose -f aws/docker-compose.yml --profile tools run --rm analyze --minutes 20
```

## 6. Скріншоти

| № | Що на скріншоті |
|---|---|
| 10.1 | VS Code: `metrics.py`, `server.py` (збір метрик, FAIL_RATE/DELAY_MS) |
| 10.2 | контейнери запущені, `cloudwatch: available`, `describe-alarms` працює |
| 10.3 | лог app1 `metrics published`, `list-metrics`: Requests, Errors, Latency |
| 10.4 | `put-metric-data` і `get-metric-statistics` (Sum, Average, Maximum) |
| 10.5 | створені Alarm у стані OK |
| 10.6 | фаза «звичайне навантаження»: лише 200, Alarm OK |
| 10.7 | фаза «помилки»: [500] у hey, `library-high-errors` = ALARM |
| 10.8 | фаза «затримки»: середній час ~0,4 с, `library-high-latency` = ALARM |
| 10.9 | відновлення: обидва Alarm OK |
| 10.10 | історія переходів Alarm |
| 10.11 | таблиця `analyze`: по хвилинах і по фазах |
| 10.12 | графік `lab10-metrics.png` |

## 7. Висновок

Застосунок сам публікує в CloudWatch три базові метрики: кількість запитів, помилок і тривалість обробки. З них через `GetMetricData` отримуються інтенсивність навантаження, частка помилок і середній час відповіді. Alarm на сумі помилок і на середньому часі відповіді переходять в ALARM протягом 1–2 хвилин після погіршення й повертаються в OK після відновлення, тож це достатній сигнал для реагування. Затримка не змінює частку помилок, а помилки не змінюють час відповіді, тому для оцінки стабільності потрібні обидва показники.
