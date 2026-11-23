# Лабораторна робота №8. Serverless-застосунок у LocalStack: Lambda + API Gateway + DynamoDB

**Мета:** перенести REST API «Онлайн бібліотеки» на serverless-архітектуру AWS (Lambda, API Gateway, DynamoDB), розгорнути його локально в LocalStack і автоматизувати розгортання сценарієм AWS CLI.

## 1. Архітектура

```
 HTTP-клієнт (Invoke-RestMethod / curl)
        │  http://localhost:4566/restapis/<api-id>/dev/_user_request_/books
        ▼
 ┌──────────────────────── LocalStack 4.14.0 (Docker) ─────────────────────────┐
 │  API Gateway (REST API "books-api", stage dev)                              │
 │     /books        ANY ─┐                                                    │
 │     /books/{id}   ANY ─┼─ AWS_PROXY ─▶  Lambda "books" (python3.12)         │
 │     /health       ANY ─┘                handler.lambda_handler              │
 │                                              │ boto3                         │
 │                                              ▼                               │
 │                                     DynamoDB таблиця "Books" (ключ id)        │
 │  CloudWatch Logs: /aws/lambda/books                                          │
 └──────────────────────────────────────────────────────────────────────────────┘
```

- **API Gateway** приймає HTTP-запит і через проксі-інтеграцію (`AWS_PROXY`) передає його в Lambda цілком: метод, шлях, тіло.
- **Lambda** розбирає маршрут, працює з DynamoDB і повертає `statusCode`, `headers`, `body`.
- **DynamoDB** зберігає книги; ключ — рядок `id`, режим оплати `PAY_PER_REQUEST`.
- **LocalStack** емулює всі ці сервіси на одному порту `4566`. Lambda він запускає в окремому Docker-контейнері, тому в `docker-compose.yml` підмонтовано `/var/run/docker.sock`.

## 2. Що зроблено в коді

| Файл | Призначення |
|---|---|
| `aws/docker-compose.yml` | LocalStack `localstack/localstack:4.14.0`, сервіси lambda, apigateway, dynamodb, iam, sts, logs, cloudwatch; мережа `library-aws` |
| `aws/lambda/handler.py` | Lambda: маршрути `GET/POST /books`, `GET/DELETE /books/{id}`, `GET /health`, валідація, JSON-логи |
| `aws/iam/trust-policy.json` | політика довіри для ролі Lambda |
| `aws/deploy.ps1` | **сценарій AWS CLI** (Windows): пакує код, створює таблицю, роль, функцію, REST API, інтеграції, дозвіл і deployment; можна запускати повторно |
| `aws/deploy.sh` | той самий сценарій для bash (Linux / macOS / WSL) |
| `aws/tests/test_handler.py` | 11 тестів Lambda з емуляцією DynamoDB (moto) |
| `scripts/lab8.ps1` | покроковий запуск ЛР-8 зі зупинками для скріншотів |

**Чому LocalStack 4.14.0.** З 23 березня 2026 нові образи LocalStack вимагають акаунт і `LOCALSTACK_AUTH_TOKEN`. 4.14 — остання версія спільноти, яка працює без реєстрації.

**AWS CLI** запускається в Docker (`amazon/aws-cli:2.15.0`) з параметром `--endpoint-url`, тож на Windows нічого не треба встановлювати. Якщо AWS CLI встановлено локально (`winget install Amazon.AWSCLI`), ті самі команди працюють з `--endpoint-url http://localhost:4566` і ключами `test` / `test`.

### Послідовність розгортання (`aws/deploy.ps1`)

| Крок | Команда AWS CLI | Результат |
|---|---|---|
| 1 | `Compress-Archive` | `build/books.zip` з `handler.py` |
| 2 | `dynamodb create-table` + `wait table-exists` | таблиця `Books` |
| 3 | `iam create-role` | роль `lambda-books-role` |
| 4 | `lambda create-function` / `update-function-code` + `wait function-active-v2` | функція `books` |
| 5 | `apigateway create-rest-api`, `create-resource` ×3, `put-method ANY`, `put-integration AWS_PROXY` | API `books-api` |
| 6 | `lambda add-permission` | API Gateway може викликати Lambda |
| 7 | `apigateway create-deployment --stage-name dev` | опублікований API, адреса в `build/api-url.txt` |

### HTTP API

| Метод | Шлях | Відповідь |
|---|---|---|
| GET | `/health` | `200 {"status":"ok","instance":"lambda"}` |
| GET | `/books` | `200 [ ...книги... ]` |
| POST | `/books` | `201 {id, title, author, year, available, created_at}`, або `400` при помилці валідації |
| GET | `/books/{id}` | `200` книга або `404` |
| DELETE | `/books/{id}` | `204` або `404` |

## 3. Запуск

```powershell
git checkout lab8
git pull
powershell -ExecutionPolicy Bypass -File scripts\lab8.ps1
```

Вручну:

```powershell
docker compose -f aws/docker-compose.yml up -d
powershell -ExecutionPolicy Bypass -File aws\deploy.ps1
$Base = Get-Content aws\build\api-url.txt
Invoke-RestMethod "$Base/health"
Invoke-RestMethod -Method POST "$Base/books" -ContentType 'application/json' -Body '{"title":"Kobzar","author":"Shevchenko","year":1840}'
Invoke-RestMethod "$Base/books"
```

Перший виклик Lambda триває до 1–2 хв: LocalStack завантажує образ середовища python3.12.

## 4. Скріншоти

| № | Що на скріншоті |
|---|---|
| 8.1 | VS Code: папка `aws/` і `handler.py` |
| 8.2 | `docker ps` — контейнер localstack, список сервісів `available` |
| 8.3 | `aws --version` і `sts get-caller-identity` (акаунт 000000000000) |
| 8.4 | вивід `aws\deploy.ps1`, кроки 0–7 і адреса API |
| 8.5 | таблиця Books, функція books, ресурси API з методом ANY |
| 8.6 | `/health` і створення двох книг (201) |
| 8.7 | `GET /books` і `GET /books/{id}` |
| 8.8 | `DELETE` → 204, повторний `GET` → 404, некоректний `POST` → 400 |
| 8.9 | `curl -i`: статус, заголовки, тіло |
| 8.10 | `dynamodb scan` — дані в таблиці |
| 8.11 | логи Lambda в CloudWatch Logs |

## 5. Висновок

REST API «Онлайн бібліотеки» перенесено на serverless-архітектуру. API Gateway маршрутизує HTTP-запити в Lambda, Lambda зберігає дані в DynamoDB. Усі ресурси створюються одним повторно запусканим сценарієм AWS CLI. LocalStack дає змогу відпрацювати розгортання без акаунта AWS і без витрат.
