# Онлайн бібліотека — ЛР-2. Continuous Integration (GitHub Actions, GHCR, Trivy, захист гілки)

Це гілка **`lab2`**: код станом на кінець лабораторної роботи №2. Звіт з усіма командами й місцями для скріншотів — [docs/LAB2.md](docs/LAB2.md).

## Застосунок

| Сервіс | Стек | Порт | Що робить |
|---|---|---|---|
| `frontend` | HTML/JS + Nginx | 80 | сторінка каталогу; проксує `/api/*` на backend |
| `backend` | Python 3.12, Flask, Gunicorn | 5000 | REST API книг |
| `db` | PostgreSQL 16 | 5432 | зберігає книги |

Ендпоінти backend: `/health`, `/version`, `/api/info`, `/api/books` (GET/POST, пошук `?q=`), `/api/books/<id>/borrow`, `/api/books/<id>/return`, `DELETE /api/books/<id>`.

## Що лежить у гілці

| Шлях | Призначення |
|---|---|
| `.github/workflows/ci.yml` | CI: lint, build, test, образи, Trivy, публікація в GHCR **(нове)** |
| `backend/` | Flask API + тести (pytest) + Ruff **(нове)** |
| `frontend/` | сторінка + ESLint/HTMLHint + тести (node:test) + Nginx **(нове)** |
| `docker-compose.yml` | локальний запуск зі збіркою (ЛР-1) **(нове)** |
| `docker-compose.ghcr.yml` | запуск опублікованих образів з GHCR **(нове)** |
| `docs/LAB2.md` | звіт ЛР-2 |

## Запуск ЛР-2

Пайплайн запускається сам на push у `main`, на Pull Request у `main` і на git-теги `v*`
(релізи). Локальна перевірка:

```powershell
docker compose up --build            # http://localhost:8080
cd backend;  pip install -r requirements-dev.txt; ruff check .; pytest -v
cd ..\frontend; npm ci; npm run lint; npm run build; npm test
```

Повний хід роботи — у [docs/LAB2.md](docs/LAB2.md).

## Образи

`ghcr.io/1nxiz/online-library-backend` і `ghcr.io/1nxiz/online-library-frontend`. Версії створює CI при публікації релізу (git-тега `vX.Y.Z`); для ЛР-3…6 потрібні 1.0.0, 1.1.0, 1.2.0, 1.3.0.

## Усі лабораторні

| ЛР | Тема | Гілка |
|---|---|---|
| 2 | Continuous Integration (GitHub Actions, GHCR, Trivy, захист гілки) | [`lab2`](https://github.com/1nxiz/online-library/tree/lab2) ← ви тут |
| 3 | Розгортання застосунку в Kubernetes (minikube, kubectl) | [`lab3`](https://github.com/1nxiz/online-library/tree/lab3) |
| 4 | Пакування застосунку в Helm-чарт (dev/prod, хук, helm test) | [`lab4`](https://github.com/1nxiz/online-library/tree/lab4) |
| 5 | GitOps: розгортання через Argo CD (App of Apps, selfHeal, revert) | [`lab5`](https://github.com/1nxiz/online-library/tree/lab5) |
| 6 | Progressive delivery: canary з Argo Rollouts | [`lab6`](https://github.com/1nxiz/online-library/tree/lab6) |
| 7 | Observability: метрики, логи, дашборди й відкат за метриками | [`lab7`](https://github.com/1nxiz/online-library/tree/lab7) |
