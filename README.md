# Онлайн бібліотека — лабораторні роботи з технологій DevOps

Мікросервісний застосунок: каталог книг з пошуком, видачею та поверненням.

| Сервіс | Стек | Порт | Що робить |
|---|---|---|---|
| `frontend` | HTML/JS + Nginx | 80 | сторінка каталогу; проксує `/api/*` на backend |
| `backend` | Python 3.12, Flask, Gunicorn | 5000 | REST API книг, `/health`, `/version` |
| `db` | PostgreSQL 16 | 5432 | зберігає книги |

## API backend

| Метод | Шлях | Опис |
|---|---|---|
| GET | `/health` | стан, версія та ім'я пода |
| GET | `/version`, `/api/version` | версія застосунку (для ЛР-5/6) |
| GET | `/api/info` | назва бібліотеки (з ConfigMap) і версія |
| GET | `/api/books?q=...` | список книг, пошук за назвою/автором |
| POST | `/api/books` | додати книгу `{title, author, year}` |
| POST | `/api/books/<id>/borrow` | видати книгу |
| POST | `/api/books/<id>/return` | повернути книгу |
| DELETE | `/api/books/<id>` | видалити книгу |

Версія «зашивається» в образ під час збірки (`APP_VERSION` = git-тег без `v` або `sha-xxxxxxx`) і показується бейджем біля заголовка сторінки.

## Структура репозиторію

```
.github/workflows/ci.yml   ЛР-2  CI: lint, build, test, образи, Trivy, GHCR
backend/                   Flask API + тести (pytest) + Ruff
frontend/                  сторінка + ESLint/HTMLHint + тести (node:test) + Nginx
docker-compose.yml         ЛР-1  локальний запуск зі збіркою
docker-compose.ghcr.yml    ЛР-2  запуск опублікованих образів
k8s/                       ЛР-3  маніфести Kubernetes (по файлу на об'єкт)
charts/online-library/     ЛР-4  Helm-чарт (+ values-minikube.yaml для ЛР-5/6)
bootstrap/root-app.yaml    ЛР-5  кореневий Application (App of Apps)
argocd-apps/               ЛР-5/6 Application застосунку і контролера Argo Rollouts
docs/LAB2.md … LAB6.md     звіти: хід виконання, команди, список скріншотів
```

## Перший крок: вкажіть свій GitHub-логін

У маніфестах, чарті та Argo CD стоїть заглушка `1nxiz`. У VS Code натисніть
**Ctrl+Shift+H**, у полі пошуку введіть `1nxiz`, у полі заміни — ваш логін
**маленькими літерами** (GHCR вимагає нижній регістр) → **Replace All**.

## Локальний запуск (Docker Compose)

```powershell
docker compose up --build
```

Відкрити http://localhost:8080. Зупинка: `docker compose down` (або `down -v`, щоб видалити й дані).

## Тести і лінтери локально

```powershell
# backend
cd backend
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
ruff check .; ruff format --check .; pytest -v

# frontend
cd ..\frontend
npm ci
npm run lint; npm run build; npm test
```

## Лабораторні роботи

| ЛР | Тема | Звіт |
|---|---|---|
| 2 | Continuous Integration (GitHub Actions, GHCR, Trivy, branch protection) | [docs/LAB2.md](docs/LAB2.md) |
| 3 | Розгортання в Kubernetes (minikube) | [docs/LAB3.md](docs/LAB3.md) |
| 4 | Helm-чарт, середовища dev/prod, хук і `helm test` | [docs/LAB4.md](docs/LAB4.md), [чарт](charts/online-library/README.md) |
| 5 | GitOps з Argo CD (App of Apps, selfHeal, revert) | [docs/LAB5.md](docs/LAB5.md) |
| 6 | Progressive delivery: canary з Argo Rollouts | [docs/LAB6.md](docs/LAB6.md) |

Скріншоти складайте в `docs/screenshots/` з іменами, вказаними у кожному звіті.

## Версії образів

Образи з семантичними тегами створює CI при push git-тега:

```powershell
git tag v1.0.0; git push origin v1.0.0   # -> образи :1.0.0
git tag v1.1.0; git push origin v1.1.0   # -> образи :1.1.0
```

Для всіх лабораторних знадобляться теги **1.0.0, 1.1.0, 1.2.0, 1.3.0**. Різниця між ними видна одразу:
сторінка і `/version` показують свій номер версії.
