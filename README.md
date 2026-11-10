# Онлайн бібліотека — ЛР-7. Observability: метрики, логи, дашборди й відкат за метриками

Це гілка **`lab7`**: код станом на кінець лабораторної роботи №7. Звіт з усіма командами й місцями для скріншотів — [docs/LAB7.md](docs/LAB7.md).

Що саме додано в цій роботі, видно в порівнянні гілок: [lab6...lab7](https://github.com/1nxiz/online-library/compare/lab6...lab7).

## Застосунок

| Сервіс | Стек | Порт | Що робить |
|---|---|---|---|
| `frontend` | HTML/JS + Nginx | 80 | сторінка каталогу; проксує `/api/*` на backend |
| `backend` | Python 3.12, Flask, Gunicorn | 5000 | REST API книг, `/metrics` |
| `db` | PostgreSQL 16 | 5432 | зберігає книги |

Ендпоінти backend: `/health`, `/version`, `/api/info`, `/api/books` (GET/POST, пошук `?q=`), `/api/books/<id>/borrow`, `/api/books/<id>/return`, `DELETE /api/books/<id>`, `/metrics` (Prometheus).

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
| `argocd-apps/kps.yaml, loki.yaml, alloy.yaml` | Prometheus + Grafana, Loki, Alloy з Git **(нове)** |
| `charts/online-library/templates/servicemonitor.yaml` | збір метрик backend **(нове)** |
| `charts/online-library/dashboards/online-library.json` | дашборд Grafana (через ConfigMap) **(нове)** |
| `charts/online-library/templates/analysistemplate.yaml` | аналіз частки успішних запитів **(нове)** |
| `charts/online-library/templates/prometheusrule.yaml` | алерт на частку 5xx > 5% **(нове)** |
| `load/` | генератори навантаження **(нове)** |
| `docs/LAB7.md` | звіт ЛР-7 |

## Запуск ЛР-7

Argo CD стежить саме за цією гілкою (`targetRevision: lab7`), тому всі коміти ЛР-7
робіть у ній: `git checkout lab7`. Стек важкий: minikube потрібен з 4 CPU і 8 ГБ.

```powershell
minikube delete; minikube start --cpus 4 --memory 8192
# Argo CD, два Secret і root — див. docs/LAB7.md, розділ 2.1
kubectl apply -f bootstrap/root-app.yaml
```

Повний хід роботи — у [docs/LAB7.md](docs/LAB7.md).

## Образи

`ghcr.io/1nxiz/online-library-backend` і `ghcr.io/1nxiz/online-library-frontend`. Версії створює CI при публікації релізу (git-тега `vX.Y.Z`); для ЛР-7 потрібні **2.0.0** і **2.1.0**, створені з гілки `lab7`.

## Усі лабораторні

| ЛР | Тема | Гілка |
|---|---|---|
| 2 | Continuous Integration (GitHub Actions, GHCR, Trivy, захист гілки) | [`lab2`](https://github.com/1nxiz/online-library/tree/lab2) |
| 3 | Розгортання застосунку в Kubernetes (minikube, kubectl) | [`lab3`](https://github.com/1nxiz/online-library/tree/lab3) |
| 4 | Пакування застосунку в Helm-чарт (dev/prod, хук, helm test) | [`lab4`](https://github.com/1nxiz/online-library/tree/lab4) |
| 5 | GitOps: розгортання через Argo CD (App of Apps, selfHeal, revert) | [`lab5`](https://github.com/1nxiz/online-library/tree/lab5) |
| 6 | Progressive delivery: canary з Argo Rollouts | [`lab6`](https://github.com/1nxiz/online-library/tree/lab6) |
| 7 | Observability: метрики, логи, дашборди й відкат за метриками | [`lab7`](https://github.com/1nxiz/online-library/tree/lab7) ← ви тут |
