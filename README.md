# Онлайн бібліотека — ЛР-9. Балансування навантаження: 3 екземпляри за nginx

Це гілка **`lab9`**: код станом на кінець лабораторної роботи №9. Звіт з усіма командами й місцями для скріншотів — [docs/LAB9.md](docs/LAB9.md).

Що саме додано в цій роботі, видно в порівнянні гілок: [lab8...lab9](https://github.com/1nxiz/online-library/compare/lab8...lab9).

## Serverless-версія (ЛР-8…10)

Той самий каталог книг у вигляді Lambda-функції (`aws/lambda/handler.py`) з даними в DynamoDB, розгорнутий у LocalStack. Маршрути: `GET /health`, `GET/POST /books`, `GET/DELETE /books/{id}`.

## Застосунок (Kubernetes-версія, ЛР-2…7)

| Сервіс | Стек | Порт | Що робить |
|---|---|---|---|
| `frontend` | HTML/JS + Nginx | 80 | сторінка каталогу; проксує `/api/*` на backend |
| `backend` | Python 3.12, Flask, Gunicorn | 5000 | REST API книг |
| `db` | PostgreSQL 16 | 5432 | зберігає книги |

Ендпоінти backend: `/health`, `/version`, `/api/info`, `/api/books` (GET/POST, пошук `?q=`), `/api/books/<id>/borrow`, `/api/books/<id>/return`, `DELETE /api/books/<id>`.

## Що лежить у гілці

| Шлях | Призначення |
|---|---|
| `.github/workflows/ci.yml` | CI: lint, build, test, образи, Trivy, публікація в GHCR |
| `backend/` | Flask API + тести (pytest) + Ruff |
| `frontend/` | сторінка + ESLint/HTMLHint + тести (node:test) + Nginx |
| `docker-compose.yml` | локальний запуск зі збіркою (ЛР-1) |
| `docker-compose.ghcr.yml` | запуск опублікованих образів з GHCR |
| `k8s/` | маніфести Kubernetes, по файлу на об'єкт |
| `charts/online-library/` | Helm-чарт (values, values-dev, values-prod) |
| `charts/online-library/values-minikube.yaml` | значення для Argo CD на minikube |
| `bootstrap/root-app.yaml` | кореневий Application (App of Apps), єдиний ручний apply |
| `argocd-apps/online-library.yaml` | Application застосунку |
| `argocd-apps/argo-rollouts.yaml` | контролер Argo Rollouts з Git |
| `charts/online-library/templates/backend-rollout.yaml` | Rollout (canary) замість Deployment |
| `argocd-apps/kps.yaml, loki.yaml, alloy.yaml` | Prometheus + Grafana, Loki, Alloy з Git |
| `charts/online-library/templates/servicemonitor.yaml` | збір метрик backend |
| `charts/online-library/dashboards/online-library.json` | дашборд Grafana (через ConfigMap) |
| `charts/online-library/templates/analysistemplate.yaml` | аналіз частки успішних запитів |
| `charts/online-library/templates/prometheusrule.yaml` | алерт на частку 5xx > 5% |
| `load/` | генератори навантаження |
| `aws/docker-compose.yml` | LocalStack 4.14.0 (емулятор AWS) |
| `aws/lambda/handler.py` | Lambda-функція: CRUD книг у DynamoDB |
| `aws/deploy.ps1, aws/deploy.sh` | сценарій AWS CLI: DynamoDB, IAM, Lambda, API Gateway |
| `aws/app/` | контейнерна версія застосунку (той самий handler.py) **(нове)** |
| `aws/nginx/nginx.conf` | балансувальник round-robin на 3 екземпляри **(нове)** |
| `docs/LAB9.md` | звіт ЛР-9 |

## Запуск ЛР-9

**Найпростіше — покроковий скрипт** (сам виконує всі команди і зупиняється там, де потрібен скріншот):

```powershell
git checkout lab9
git pull
powershell -ExecutionPolicy Bypass -File scripts\lab9.ps1
```

Потрібен лише Docker Desktop: LocalStack, AWS CLI і nginx запускаються в контейнерах.

Вручну:

```powershell
docker compose -f aws/docker-compose.yml up -d --build
Invoke-RestMethod http://localhost:8080/health   # повторіть кілька разів: instance змінюється
```

Повний хід роботи — у [docs/LAB9.md](docs/LAB9.md).

## Усі лабораторні

| ЛР | Тема | Гілка |
|---|---|---|
| 2 | Continuous Integration (GitHub Actions, GHCR, Trivy, захист гілки) | [`lab2`](https://github.com/1nxiz/online-library/tree/lab2) |
| 3 | Розгортання застосунку в Kubernetes (minikube, kubectl) | [`lab3`](https://github.com/1nxiz/online-library/tree/lab3) |
| 4 | Пакування застосунку в Helm-чарт (dev/prod, хук, helm test) | [`lab4`](https://github.com/1nxiz/online-library/tree/lab4) |
| 5 | GitOps: розгортання через Argo CD (App of Apps, selfHeal, revert) | [`lab5`](https://github.com/1nxiz/online-library/tree/lab5) |
| 6 | Progressive delivery: canary з Argo Rollouts | [`lab6`](https://github.com/1nxiz/online-library/tree/lab6) |
| 7 | Observability: метрики, логи, дашборди й відкат за метриками | [`lab7`](https://github.com/1nxiz/online-library/tree/lab7) |
| 8 | Serverless у LocalStack: Lambda, API Gateway, DynamoDB | [`lab8`](https://github.com/1nxiz/online-library/tree/lab8) |
| 9 | Балансування навантаження: 3 екземпляри за nginx | [`lab9`](https://github.com/1nxiz/online-library/tree/lab9) ← ви тут |
| 10 | Метрики CloudWatch у LocalStack: PutMetricData, Alarm, графіки | [`lab10`](https://github.com/1nxiz/online-library/tree/lab10) |
