# Helm-чарт `online-library`

Розгортає «Онлайн бібліотеку»: frontend (Nginx), backend (Flask) і PostgreSQL. Дає той самий набір об'єктів, що й маніфести `k8s/` з ЛР-3.

## version vs appVersion

- **`version: 0.1.0`** — версія **чарта**, тобто шаблонів і значень. Її збільшують, коли змінюється сам чарт: додали шаблон, параметр, змінили структуру values.
- **`appVersion: "1.0.0"`** — версія **застосунку**, тобто образів backend/frontend. Вона береться як тег образу, якщо `image.tag` порожній, і записується в мітку `app.kubernetes.io/version`.

Отже, один і той самий чарт `0.1.0` може розгортати різні версії застосунку (`--set backend.image.tag=1.1.0`), а нова версія чарта не обов'язково означає нову версію застосунку.

## Шаблони

| Шаблон | Об'єкт | Умова |
|---|---|---|
| `_helpers.tpl` | іменовані шаблони `library.fullname`, `library.componentName`, `library.labels`, `library.componentLabels`, `library.selectorLabels`, `library.image`, `library.backendPod` | — |
| `configmap.yaml` | ConfigMap | завжди |
| `secret.yaml` | Secret | якщо не задано `secret.existingSecret` |
| `postgres-pvc.yaml` | PVC | `postgres.persistence.enabled` |
| `postgres-deployment.yaml`, `postgres-service.yaml` | БД | завжди |
| `backend-deployment.yaml` | Deployment | завжди |
| `backend-service.yaml`, `frontend-*.yaml` | Deployment/Service | завжди |
| `ingress.yaml` | Ingress | `ingress.enabled` |
| `pre-upgrade-job.yaml` | Job-хук `pre-upgrade` (перевірка БД) | `hooks.enabled` |
| `tests/test-connection.yaml` | тест `helm test` | `tests.enabled` |
| `NOTES.txt` | підказка, як відкрити застосунок | — |

Усі імена будуються з імені релізу (`<release>-online-library-<компонент>`), тож чарт можна встановити двічі в один кластер.

## Параметри values

| Параметр | Опис | values.yaml (dev за замовч.) | values-dev.yaml | values-prod.yaml |
|---|---|---|---|---|
| `backend.replicaCount` | репліки backend | 2 | 1 | 3 |
| `backend.progressDeadlineSeconds` | таймаут оновлення | 90 | — | — |
| `backend.image.repository` | образ backend | `ghcr.io/1nxiz/online-library-backend` | — | — |
| `backend.image.tag` | тег образу backend | `1.0.0` | `1.1.0` | `1.0.0` |
| `backend.service.type` / `.port` | Service backend | ClusterIP / 5000 | — | — |
| `backend.resources` | requests/limits | 100m/128Mi – 500m/256Mi | 50m/64Mi – 250m/192Mi | 200m/256Mi – 1/512Mi |
| `frontend.replicaCount` | репліки frontend | 2 | 1 | 3 |
| `frontend.image.repository` / `.tag` | образ frontend | `…-frontend` / `1.0.0` | `1.1.0` | `1.0.0` |
| `frontend.service.type` | тип Service | NodePort | NodePort | ClusterIP |
| `frontend.service.port` / `.nodePort` | порти | 80 / авто | — | — |
| `frontend.resources` | requests/limits | 50m/32Mi – 200m/128Mi | — | 100m/64Mi – 300m/128Mi |
| `config.appTitle` | заголовок сторінки | `Онлайн бібліотека (dev)` | `… (dev)` | `Онлайн бібліотека` |
| `config.logLevel` | рівень логів | DEBUG | DEBUG | WARNING |
| `config.dbName` / `config.dbUser` | БД і користувач | library / library | — | — |
| `secret.existingSecret` | готовий Secret з `DB_PASSWORD` | `""` | — | — |
| `secret.dbPassword` | пароль БД, якщо Secret створює чарт | `dev-only-password` | — | `""` → передати `--set` |
| `postgres.image` | образ БД | `postgres:16-alpine` | — | — |
| `postgres.persistence.enabled` / `.size` | PVC | true / 1Gi | false | true / 5Gi |
| `ingress.enabled` / `.className` / `.host` | Ingress | false / nginx / library.local | false | true |
| `hooks.enabled` | хук pre-upgrade | true | — | — |
| `tests.enabled` | тест `helm test` | true | — | — |

## Встановлення

```powershell
# dev
helm install library-dev charts/online-library -n library-dev --create-namespace -f charts/online-library/values-dev.yaml

# prod (пароль лише через --set, у файлах його немає)
helm install library-prod charts/online-library -n library-prod --create-namespace `
  -f charts/online-library/values-prod.yaml --set secret.dbPassword=<пароль>
```

Пріоритет значень (від найнижчого): `values.yaml` чарта → файли `-f` (кожен наступний перекриває попередній) → `--set` / `--set-string`.
