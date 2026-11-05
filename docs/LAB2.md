# Лабораторна робота №2. Continuous Integration

**Мета:** автоматично перевіряти, збирати та публікувати сервіси «Онлайн бібліотеки» при кожній зміні коду.

**Обрані інструменти:** GitHub Actions (CI), Ruff (Python), ESLint + HTMLHint (JS/HTML), pytest і node:test (тести), Docker Buildx, Trivy (сканування образів), GitHub Container Registry `ghcr.io` (реєстр).

## 1. Що зроблено в коді

| Файл | Пояснення |
|---|---|
| `.github/workflows/ci.yml` | пайплайн; запускається на `pull_request` у `main`, на `push` у `main` і на git-теги `v*` |
| `backend/pyproject.toml` | правила Ruff (`E,W,F,I,B,UP`) і налаштування pytest |
| `backend/requirements-dev.txt` | залежності для CI: pytest, ruff |
| `backend/tests/test_app.py` | 14 юніт-тестів API (БД підміняється через `monkeypatch`) |
| `frontend/package.json` | скрипти `lint`, `build`, `test` |
| `frontend/eslint.config.js`, `.htmlhintrc` | правила статичного аналізу |
| `frontend/scripts/build.mjs` | збірка (bundling) `src/` → `dist/` |
| `frontend/tests/lib.test.js` | юніт-тести функцій валідації та форматування |
| `backend/Dockerfile`, `frontend/Dockerfile` | Dockerfile з ЛР-1, доповнені: `ARG APP_VERSION`, non-root користувач, multi-stage збірка фронтенду |

### Структура пайплайну

```
 PR / push / tag
   ├─ backend  : checkout → Python+кеш pip → Lint (Ruff) → Build → Test (pytest)
   ├─ frontend : checkout → Node+кеш npm   → Lint (ESLint, HTMLHint) → Build → Test
   │      (паралельно і незалежно)
   └─ docker (matrix: backend, frontend)        needs: [backend, frontend]
         Build image (local, без push) → Trivy (блокує при HIGH/CRITICAL)
         → [лише push] login ghcr.io → Push (теги sha-xxxxxxx, latest для main, 1.2.3 для git-тега)
```

Як виконано кожну вимогу:

- **Окреме завдання для кожного сервісу:** `backend` і `frontend` — окремі jobs (різні стеки, тому без matrix). Образи збираються в одному job `docker` через `matrix.service`.
- **Паралельність і незалежність:** jobs без `needs` між собою виконуються паралельно. У matrix стоїть `fail-fast: false`, тому падіння одного образу не скасовує інший.
- **Кешування:** `actions/setup-python` з `cache: pip` і `actions/setup-node` з `cache: npm`. Шари Docker кешуються через `cache-from/cache-to: type=gha`.
- **Лінтер блокуючий:** Ruff або ESLint завершуються з ненульовим кодом, тож job падає. `ruff --output-format=github` показує зауваження анотаціями прямо у вкладці *Files changed* PR.
- **Образи після тестів:** `needs: [backend, frontend]`. На кроці `Build image (local)` стоїть `push: false, load: true`, тобто образ лише збирається на раннері.
- **Trivy:** `exit-code: "1"` для `CRITICAL,HIGH` блокує публікацію. Версія `aquasecurity/trivy-action@0.35.0` захищена від інциденту з підміною тегів у березні 2026.
- **Публікація лише для push:** `if: github.event_name == 'push'`. Вхід через `secrets.GITHUB_TOKEN` (дозвіл `packages: write`), тож паролів у репозиторії немає.
- **Теги:** `sha-<7 символів>` як унікальний тег збірки; `latest` лише для основної гілки (`enable={{is_default_branch}}`); `1.1.0` і `1.1` при push тега `v1.1.0`.

## 2. Хід виконання

### 2.1. Репозиторій на GitHub

1. Створіть на GitHub **публічний** репозиторій `online-library`. Для приватного Branch Protection доступний лише на платних планах.
2. У VS Code замініть `1nxiz` на свій логін (див. README).
3. Завантажте код:

```powershell
git init
git add .
git commit -m "Online library + CI pipeline"
git branch -M main
git remote add origin https://github.com/<логін>/online-library.git
git push -u origin main
```

4. Відкрийте вкладку **Actions** і дочекайтеся зеленого запуску (4 jobs).
5. Перезапустіть workflow (**Re-run all jobs**). У логах кроку *Setup Python* / *Setup Node* з'явиться `Cache restored`, і крок `Install dependencies` пройде швидше.

### 2.2. Публікація та перевірка образів

1. **Profile → Packages** покаже `online-library-backend` і `online-library-frontend` з тегами `sha-…` і `latest`.
2. Якщо пакет **Private**, зробіть його публічним: *Package settings → Change visibility → Public*. Це потрібно для minikube у ЛР-3…6.
3. Створіть версії для наступних лабораторних:

```powershell
git tag v1.0.0; git push origin v1.0.0
git tag v1.1.0; git push origin v1.1.0
git tag v1.2.0; git push origin v1.2.0
git tag v1.3.0; git push origin v1.3.0
```

4. Перевірте працездатність опублікованих образів:

```powershell
docker pull ghcr.io/<логін>/online-library-backend:latest
docker pull ghcr.io/<логін>/online-library-frontend:latest
$env:GH_USER="<логін>"; $env:TAG="latest"
docker compose -f docker-compose.ghcr.yml up
```

Відкрийте http://localhost:8080 і додайте кілька книг. Біля заголовка буде бейдж версії `vsha-…`; для `$env:TAG="1.1.0"` буде `v1.1.0`.

### 2.3. Захист гілки main

**Settings → Branches → Add classic branch protection rule**, шаблон `main`:

- ☑ *Require a pull request before merging*
- ☑ *Require status checks to pass before merging* і ☑ *Require branches to be up to date*. У пошуку додайте `backend`, `frontend`, `docker (backend)`, `docker (frontend)`. Перевірки з'являються в пошуку лише після того, як хоча б раз виконались.
- ☑ *Do not allow bypassing the above settings*

Перевірка, що прямий push заборонено:

```powershell
git commit --allow-empty -m "direct push test"
git push origin main     # remote rejected: protected branch hook declined
git reset --hard HEAD~1
```

### 2.4. Демонстрація заблокованого PR

```powershell
git checkout -b broken-lint
```

У `backend/app.py` додайте другим рядком невикористаний імпорт `import sys`, а в `backend/tests/test_app.py` у `test_health` змініть `200` на `201`. Потім:

```powershell
git commit -am "Break lint and tests on purpose"
git push -u origin broken-lint
```

Відкрийте Pull Request `broken-lint → main`. Результат: job `backend` червоний, на вкладці *Files changed* анотація Ruff `F401 sys imported but unused`, `docker (*)` пропущені (*skipped*), кнопка **Merge** недоступна з повідомленням *Merging is blocked*. Після цього PR закрийте без злиття.

## 3. Скріншоти для звіту

| № | Файл у `docs/screenshots/` | Що має бути на скріншоті |
|---|---|---|
| 1 | `lab2-01-workflow-file.png` | `ci.yml` у VS Code (тригери `on:` і список jobs) |
| 2 | `lab2-02-actions-graph.png` | граф запуску в Actions: `backend` ‖ `frontend` → `docker (backend)`, `docker (frontend)`, усе зелене |
| 3 | `lab2-03-backend-steps.png` | розгорнутий job `backend` з кроками Lint / Build / Test і результатом `14 passed` |
| 4 | `lab2-04-frontend-steps.png` | job `frontend`: Lint / Build / Test (`# pass 5`) |
| 5 | `lab2-05-cache.png` | повторний запуск: рядок `Cache restored from key …` |
| 6 | `lab2-06-trivy.png` | крок `Scan image (Trivy)` з таблицею (0 HIGH/CRITICAL) |
| 7 | `lab2-07-pr-checks.png` | PR з успішними перевірками в блоці *Checks* |
| 8 | `lab2-08-ghcr-packages.png` | сторінка пакета в GHCR з тегами `sha-…`, `latest`, `1.0.0`, `1.1.0` |
| 9 | `lab2-09-docker-pull-run.png` | термінал: `docker pull …` і `docker compose -f docker-compose.ghcr.yml up` + браузер з застосунком |
| 10 | `lab2-10-branch-protection.png` | налаштування правила захисту `main` з required checks |
| 11 | `lab2-11-direct-push-rejected.png` | термінал: `protected branch hook declined` |
| 12 | `lab2-12-pr-blocked.png` | PR `broken-lint`: червоний `backend`, *Merging is blocked* |
| 13 | `lab2-13-ruff-annotation.png` | анотація Ruff `F401` у *Files changed* |

## 4. Висновок

Налаштовано CI на GitHub Actions. Кожен PR і push автоматично проходить статичний аналіз, збірку і тести обох сервісів паралельно. Далі збираються й скануються Docker-образи, а при push вони публікуються в GHCR з унікальним тегом і `latest`. Branch protection не дає злити зміни, що не пройшли перевірки.
