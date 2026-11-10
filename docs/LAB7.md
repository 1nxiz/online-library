# Лабораторна робота №7. Observability: метрики, логи, дашборди й відкат за метриками

**Мета:** зробити поведінку застосунку видимою (метрики, логи, дашборд) і використати ці дані, щоб реліз сам відкотився, якщо нова версія сипле помилками.

**Вихідні дані:** «Онлайн бібліотека» під керуванням Argo CD і Argo Rollouts (canary) з ЛР-5 і ЛР-6. Уся робота — у гілці `lab7`.

## 1. Що зроблено в коді

### 1.1. Стек моніторингу (п.1)

| Файл | Що встановлює | Версія чарта |
|---|---|---|
| `argocd-apps/kps.yaml` | kube-prometheus-stack: Prometheus, Alertmanager, Grafana, CRD ServiceMonitor/PrometheusRule | 93.1.1 |
| `argocd-apps/loki.yaml` | Loki в режимі одного процесу, файлове сховище | 21.1.1 (`grafana-community`) |
| `argocd-apps/alloy.yaml` | Grafana Alloy: 1 репліка, читає логи всіх подів через Kubernetes API → Loki | 1.15.0 |

Важливі налаштування:
- `fullnameOverride: kps` дає короткі імена `kps-prometheus` і `kps-grafana`.
- `ServerSideApply=true`, бо CRD kube-prometheus-stack завеликі для звичайного apply.
- `...NilUsesHelmValues: false`: Prometheus бере ServiceMonitor і PrometheusRule з усіх namespace без мітки `release`.
- Пароль Grafana береться з Secret `grafana-admin`, створеного вручну. Інакше чарт генерував би новий пароль на кожній синхронізації Argo CD.
- Sidecar Grafana шукає дашборди в усіх namespace (`searchNamespace: ALL`), джерело Loki додано через `additionalDataSources`.

**Відмінності від методички** (чарт Loki 21.x):
- режим `SingleBinary` перейменовано на `Monolithic`;
- ключ `minio` схема чарта більше не приймає, з ним синхронізація впала б з помилкою `additional properties 'minio' not allowed`. Тому його прибрано.

В Alloy, крім міток `namespace`, `pod`, `app`, додано мітки `container` і `component` (backend/frontend/postgres).

### 1.2. Застосунок (п.2a, п.3, п.6b) — `backend/app.py`

| Що | Як зроблено |
|---|---|
| `GET /metrics` | `prometheus_client`: лічильник `http_requests_total{method, route, status}` і гістограма `http_request_duration_seconds{method, route}` |
| Мала кардинальність | `route` — шаблон маршруту Flask (`/api/books/<int:book_id>/borrow`), а не URL з id; невідомий шлях → `unknown` |
| Службові шляхи | `/metrics` і `/health` не рахуються і не ламаються (їх смикають Prometheus і проби) |
| JSON-логи | `JsonFormatter`: кожен рядок stdout — JSON з `time`, `level`, `msg`, `method`, `route`, `status`, `duration_ms`, `version` |
| «Погана» поведінка | `FAIL_RATE` (0…1): така частка запитів отримує `500 {"error":"injected failure"}` |
| Необроблені помилки | `errorhandler` повертає JSON 500, і такі запити теж потрапляють у метрики та логи |
| Gunicorn | `-w 1 --threads 8`: лічильники живуть у пам'яті процесу, з кількома воркерами кожен скрейп бачив би лише один з них |

Тести (`backend/tests/test_app.py`, усього 23): метрики рахуються за шаблоном маршруту, гістограма заповнюється, `/health` не рахується, `FAIL_RATE=1` дає 500 і не ламає `/health` та `/metrics`, формат JSON-логу.

### 1.3. Helm-чарт (п.2b, п.4, п.6a, п.6d)

| Шаблон | Об'єкт |
|---|---|
| `templates/servicemonitor.yaml` | ServiceMonitor: вибирає Service backend за мітками, порт `http`, шлях `/metrics`, інтервал 15 с; `podTargetLabels: [rollouts-pod-template-hash]` додає до метрик ревізію Rollout |
| `templates/dashboard.yaml` + `dashboards/online-library.json` | ConfigMap з міткою `grafana_dashboard: "1"`: дашборд приходить у Grafana з Git |
| `templates/analysistemplate.yaml` | AnalysisTemplate `online-library-success-rate`: кожні 30 с, 4 виміри, `failureLimit: 1`, умова `result[0] >= 0.95` |
| `templates/prometheusrule.yaml` | алерт `OnlineLibraryHighErrorRate`: частка 5xx > 5% протягом 1 хв |
| `templates/_helpers.tpl` | у под backend передаються `backend.env` (звідси `FAIL_RATE`) |
| `templates/backend-service.yaml` | Service backend отримав мітку `component: backend`, за нею його знаходить ServiceMonitor |

Запит аналізу (частка не-5xx відповідей за 1 хв):

```promql
sum(rate(http_requests_total{namespace="online-library",status!~"5.."}[1m]))
/
sum(rate(http_requests_total{namespace="online-library"}[1m]))
```

Стратегія canary в `values-minikube.yaml`. Ручну паузу з ЛР-6 прибрано: тепер рішення приймає аналіз.

```yaml
rollout:
  replicaCount: 5            # setWeight 20 = рівно 1 canary-под
  analysis: { enabled: true }
  canary:
    steps:
      - setWeight: 20
      - pause: { duration: 30s }   # дати метрикам накопичитися
      - analysis:
          templates:
            - templateName: online-library-success-rate
      - setWeight: 60
      - pause: { duration: 30s }
```

Якщо canary-под віддає 500 на половину запитів, він отримує ~20% трафіку, тож помилок ≈ 10%. Частка успішних ≈ 0.90 < 0.95, аналіз провалюється, і Rollout сам робить abort.

### 1.4. Дашборд «Онлайн бібліотека» (п.4)

| Панель | Запит |
|---|---|
| Запити за секунду | `sum(rate(http_requests_total{namespace="online-library"}[1m]))` (+ розбивка за `status`) |
| Частка 5xx | `sum(rate(...{status=~"5.."}[1m])) / sum(rate(...[1m]))`, одиниця percent 0–1 |
| p95 затримки | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{...}[1m])))` (+ p50) |
| 5xx по подах | `sum by (pod) (rate(http_requests_total{...,status=~"5.."}[1m]))` |
| Запити за ревізією Rollout | `sum by (rollouts_pod_template_hash) (rate(http_requests_total{...}[1m]))` — видно stable і canary |
| CPU подів | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="online-library",container!=""}[1m]))` |
| Пам'ять подів | `sum by (pod) (container_memory_working_set_bytes{namespace="online-library",container!=""})` |
| Логи помилок (Loki) | `{namespace="online-library"} \| json \| level="error"` |

Дашборд оновлюється кожні 10 с і за замовчуванням показує останні 15 хв.

### 1.5. Навантаження (п.5) — `load/load-generator.yaml`

Deployment `load` у namespace `default`, не під Argo CD. Він безперервно запитує `http://online-library-frontend.online-library.svc/api/books`, тобто як браузер: Nginx → backend → PostgreSQL. Для короткого потужного тесту використовується `hey`.

## 2. Хід виконання (PowerShell)

### 2.0. Підготовка: образи 2.0.0 і 2.1.0

Образи 1.x не мають `/metrics`. На GitHub: **Releases → Draft a new release → Choose a tag** `v2.0.0` → **Target: `lab7`** → *Publish release*. Те саме для `v2.1.0`. Дочекайтеся зеленого CI у вкладці *Actions*.

### 2.1. Кластер з 4 CPU / 8 ГБ і відновлення з Git (п.1)

```powershell
git checkout lab7
minikube delete
minikube start --driver=docker --cpus 4 --memory 8192
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w      # дочекатися Running, Ctrl+C

# секрети не з Git: БД застосунку (як у ЛР-5) і пароль Grafana
kubectl create namespace online-library
kubectl create secret generic library-db-secret -n online-library --from-literal=DB_PASSWORD=<пароль>
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password=<пароль-grafana>

kubectl apply -f bootstrap/root-app.yaml        # targetRevision: lab7
```

Вхід в Argo CD — як у ЛР-5:

```powershell
kubectl port-forward svc/argocd-server -n argocd 8443:443      # окремий термінал
argocd admin initial-password -n argocd
argocd login localhost:8443 --username admin --insecure
argocd app list       # root, argo-rollouts, kps, loki, alloy, online-library — Synced / Healthy (перший раз 5–10 хв)
kubectl -n monitoring get pods
```

Відкрити інтерфейси (кожен в окремому терміналі):

```powershell
kubectl -n monitoring port-forward svc/kps-grafana 3000:80          # http://localhost:3000  admin / <пароль-grafana>
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090     # http://localhost:9090
```

### 2.2. Метрики (п.2)

```powershell
kubectl run m --rm -it --restart=Never -n online-library --image=curlimages/curl -- curl -s http://online-library-backend:5000/metrics
```

У Prometheus: **Status → Target health**. Ціль `serviceMonitor/online-library/online-library-backend/0` має 5 ендпоінтів у стані **UP**. Потім у **Query**:

```promql
sum by (status) (rate(http_requests_total{namespace="online-library"}[1m]))
```

### 2.3. Логи (п.3)

```powershell
kubectl logs -n online-library -l app.kubernetes.io/component=backend --tail=5
```

Grafana → **Explore** → джерело **Loki** → режим *Code*:

```logql
{namespace="online-library", component="backend"}
{namespace="online-library"} | json | status >= 500
{namespace="online-library"} | json | duration_ms > 50 | line_format "{{.route}} {{.duration_ms}}ms"
sum by (pod) (count_over_time({namespace="online-library"} | json | status >= 500 [1m]))
```

Поки помилок немає, запит зі `status >= 500` повертає порожній результат — це нормально. Рядки з 5xx з'являться під час поганого релізу (п.2.7), тоді зробіть скріншот ще раз.

### 2.4. Дашборд з Git (п.4)

Grafana → **Dashboards** → «Онлайн бібліотека». Він прийшов з ConfigMap, а не створений вручну:

```powershell
kubectl get configmap -A -l grafana_dashboard=1
kubectl delete configmap online-library-dashboard -n online-library   # імітуємо втрату
argocd app get online-library --refresh                               # selfHeal повертає ConfigMap, дашборд знову на місці
```

Щоб змінити дашборд: відредагуйте в UI → **Share → Export → Save to file** → замініть `charts/online-library/dashboards/online-library.json` → commit → push.

### 2.5. Навантаження і ще одна зміна (п.5)

Grafana: діапазон **Last 15 minutes**, автооновлення **10s**.

```powershell
kubectl apply -f load/load-generator.yaml             # постійний трафік (потрібен і для п.2.6–2.7)
kubectl scale deployment load --replicas=3            # більше трафіку

# короткий потужний тест: 20 паралельних клієнтів 3 хвилини
kubectl run hey --rm -it --restart=Never --image=williamyeh/hey -- -z 3m -c 20 http://online-library-frontend.online-library.svc/api/books
```

На дашборді ростуть запити за секунду, p95 і CPU подів backend та postgres.

**Ще одна зміна: масштабування через Git.** У `values-minikube.yaml` змініть `rollout.replicaCount: 5` → `8`, потім:

```powershell
git commit -am "scale backend 5 -> 8"
git push
argocd app get online-library --refresh
```

На панелях CPU і пам'яті з'являються 3 нові поди, а навантаження розподіляється між ними. Зміна кількості реплік не змінює шаблон пода, тому canary не запускається. Після демонстрації поверніть 5 через `git revert --no-edit HEAD` і `git push`.

### 2.6. Хороший реліз: аналіз Successful (п.6a)

Відкрийте заздалегідь: Grafana, `kubectl argo rollouts get rollout online-library-backend -n online-library --watch` і переконайтеся, що працює `load`.

```powershell
# у values-minikube.yaml: backend.image.tag: "2.1.0"
git commit -am "release 2.1.0"
git push
argocd app get online-library --refresh
kubectl get analysisrun -n online-library        # ...-2-2  Successful
```

Кроки: 20% → пауза 30 с → **AnalysisRun Running → Successful** → 60% → 30 с → 100%.

### 2.7. Поганий реліз: автоматичний abort (п.6b–c)

```powershell
# у values-minikube.yaml: backend.env FAIL_RATE value: "0.5"
git commit -am "bad release: FAIL_RATE=0.5"
git push
argocd app get online-library --refresh
kubectl argo rollouts get rollout online-library-backend -n online-library --watch
```

Що відбувається:
1. Rollout створює 1 canary-под (20%), у якого `FAIL_RATE=0.5`.
2. Через 30 с стартує AnalysisRun. Частка успішних запитів падає приблизно до 0.90.
3. Два виміри нижче 0.95 → **AnalysisRun Failed** → Rollout сам робить **abort**, canary-под видаляється, усі 5 подів на stable, статус `✖ Degraded`.

```powershell
kubectl get analysisrun -n online-library
kubectl describe analysisrun -n online-library <ім'я-failed-run>    # Measurements: значення 0.9…, Phase Failed
```

На дашборді:
- «Частка 5xx» має сплеск ~10%;
- «5xx по подах» показує помилки лише з одного (canary) пода, після abort вони зникають;
- «Запити за ревізією Rollout» показує появу і зникнення canary-ревізії.

У Loki:

```logql
{namespace="online-library"} | json | status >= 500
```

Усі рядки з одного пода нового ReplicaSet: ім'я пода містить хеш canary-ревізії, не stable. Argo CD при цьому показує **Synced / Degraded**, як і в ЛР-6: Git описує `FAIL_RATE=0.5`, а кластер навмисно лишився на stable.

**Завершення відкату через Git:**

```powershell
git revert --no-edit HEAD
git push
argocd app get online-library --refresh       # Synced / Healthy
git log --oneline -5
```

### 2.8. Алерт (п.6d, за бажанням)

Prometheus → **Alerts**: правило `OnlineLibraryHighErrorRate`. Через `for: 1m` і швидкий abort алерт може встигнути лише в **Pending**. Щоб показати **Firing**, тимчасово поставте `rollout.analysis.enabled: false` і `FAIL_RATE: "0.5"` (погана версія розгорнеться повністю, ~50% 5xx). За 1–2 хв алерт стане Firing; його видно і в Alertmanager (`kubectl -n monitoring port-forward svc/kps-alertmanager 9093`). Потім `git revert` обох змін.

### 2.9. Шпаргалка для захисту (п.7)

| Показати | Де |
|---|---|
| ціль UP і запит до метрики | Prometheus → Target health; Query `sum by (status) (rate(http_requests_total{namespace="online-library"}[1m]))` |
| дашборд під навантаженням | `kubectl apply -f load/…` + `hey`, Grafana → «Онлайн бібліотека» |
| логи, фільтр 5xx | Grafana Explore → Loki: `{namespace="online-library"} \| json \| status >= 500` |
| поганий реліз сам відкочується | `FAIL_RATE: "0.5"` → push → `get rollout --watch` → AnalysisRun Failed → abort → `git revert` |

Готові запити на прохання викладача:
- PromQL: `topk(3, sum by (route) (rate(http_requests_total{namespace="online-library"}[5m])))`, `sum(up{namespace="online-library"})`.
- LogQL: `{namespace="online-library", component="backend"} |= "borrow"`, `rate({namespace="online-library"} | json | level="error" [1m])`.

### Типові проблеми

- **Поди monitoring у Pending.** Бракує пам'яті, перестворіть minikube з `--memory 8192`.
- **AnalysisRun одразу Error або Failed і для хорошої версії.** Немає трафіку (0/0 = NaN). Запустіть `load`.
- **Ціль не в Targets.** Перевірте `kubectl get servicemonitor -n online-library` і мітку `component: backend` на Service.
- **Дашборда немає.** Перевірте `kubectl get cm -A -l grafana_dashboard=1` і логи контейнера `grafana-sc-dashboard` у поді Grafana.

## 3. Скріншоти для звіту

| № | Файл | Що на скріншоті |
|---|---|---|
| 1 | `lab7-01-monitoring-apps.png` | Argo CD: `kps`, `loki`, `alloy` Synced / Healthy |
| 2 | `lab7-02-monitoring-pods.png` | `kubectl -n monitoring get pods`, усі Running |
| 3 | `lab7-03-grafana-login.png` | Grafana відкрита на localhost:3000 |
| 4 | `lab7-04-metrics-endpoint.png` | вивід `/metrics` з `http_requests_total` і `..._bucket` |
| 5 | `lab7-05-target-up.png` | Prometheus → Target health: ціль backend UP |
| 6 | `lab7-06-promql.png` | Prometheus Query з графіком `sum by (status) …` |
| 7 | `lab7-07-json-logs.png` | `kubectl logs`: JSON-рядки |
| 8 | `lab7-08-loki-explore.png` | Grafana Explore: `{namespace="online-library"} \| json \| status >= 500` |
| 9 | `lab7-09-dashboard-configmap.png` | `kubectl get cm -A -l grafana_dashboard=1` + дашборд після selfHeal |
| 10 | `lab7-10-dashboard-load.png` | дашборд під навантаженням: ріст RPS, p95, CPU |
| 11 | `lab7-11-scale-git.png` | 8 подів на панелях CPU/пам'яті після коміту |
| 12 | `lab7-12-analysis-successful.png` | `get analysisrun`: Successful для релізу 2.1.0 |
| 13 | `lab7-13-analysis-failed.png` | `get rollout --watch`: AnalysisRun Failed, Degraded, 5 stable-подів |
| 14 | `lab7-14-describe-analysisrun.png` | `describe analysisrun`: виміряні значення < 0.95 |
| 15 | `lab7-15-dashboard-errors.png` | дашборд: сплеск частки 5xx і помилки лише одного пода |
| 16 | `lab7-16-loki-canary-errors.png` | Loki: рядки 5xx лише з canary-пода |
| 17 | `lab7-17-revert.png` | `git revert`, Argo CD Synced / Healthy |
| 18 | `lab7-18-alert-firing.png` (за бажанням) | Prometheus Alerts: `OnlineLibraryHighErrorRate` Firing |

## 4. Висновок

Для «Онлайн бібліотеки» налаштовано повну спостережуваність, встановлену з Git через Argo CD:
- метрики Prometheus з низькою кардинальністю;
- JSON-логи, які збирає Alloy у Loki;
- дашборд як код у Helm-чарті.

Canary-реліз тепер перевіряється аналізом метрик: якщо частка успішних запитів падає нижче 95%, Argo Rollouts сам скасовує реліз і повертає трафік на stable-версію. Остаточно відкат завершується через `git revert`.
