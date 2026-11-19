# ЛР-7. Observability і відкат за метриками — покроковий скрипт зі зупинками для скріншотів.
# Запуск з кореня репозиторію (гілка lab7):
#   powershell -ExecutionPolicy Bypass -File scripts\lab7.ps1
. "$PSScriptRoot\common.ps1"
Start-Lab 'lab7'
Ensure-PortForward 'argocd-server' 'argocd' '8443:443' 8443

$GrafanaPassword = 'Grafana123'

Say '0. Перевірка образів 2.0.0 і 2.1.0 (з /metrics)'
foreach ($v in @('2.0.0', '2.1.0')) {
    while ($true) {
        docker manifest inspect "ghcr.io/1nxiz/online-library-backend:$v" *> $null
        if ($LASTEXITCODE -eq 0) { Write-Host "  образ $v є" -ForegroundColor Green; break }
        Write-Host "  Образу $v немає. GitHub -> Releases -> Draft a new release -> тег v$v, Target: lab7 -> Publish." -ForegroundColor Red
        Read-Host '  Дочекайтеся зеленого CI у вкладці Actions і натисніть Enter' | Out-Null
    }
}

Say '1. Стек моніторингу через Argo CD (п.1)'
kubectl get namespace monitoring *> $null
if ($LASTEXITCODE -ne 0) { Run 'kubectl create namespace monitoring' }
kubectl get secret grafana-admin -n monitoring *> $null
if ($LASTEXITCODE -ne 0) {
    Run "kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password=$GrafanaPassword"
}
Run 'kubectl apply -f bootstrap/root-app.yaml'
Refresh 'root'
foreach ($app in @('kps', 'loki', 'alloy', 'online-library')) {
    WaitFor "$app : Synced / Healthy (перший раз 5–15 хв)" { (AppStatus $app) -eq 'Synced/Healthy' } 1500
}
Run 'kubectl get applications -n argocd'
Start-Process 'https://localhost:8443/applications'
Shot '7.1' 'браузер Argo CD: kps, loki, alloy, online-library — усі Synced / Healthy'
Run 'kubectl -n monitoring get pods'
Shot '7.2' 'термінал: поди monitoring (Prometheus, Grafana, Loki, Alloy...) — Running'
Ensure-PortForward 'kps-grafana' 'monitoring' '3000:80' 3000
Ensure-PortForward 'kps-prometheus' 'monitoring' '9090:9090' 9090
Start-Process 'http://localhost:3000'
Ask "Увійдіть у Grafana: admin / $GrafanaPassword"
Shot '7.3' 'браузер: Grafana після входу'

Say '2. Навантаження (п.5) — потрібне для метрик і аналізу'
Run 'kubectl apply -f load/load-generator.yaml'

Say '3. Метрики (п.2)'
kubectl delete pod m -n online-library --ignore-not-found *> $null
Show 'kubectl run m --rm -i --restart=Never -n online-library --image=curlimages/curl -- curl -s http://online-library-backend:5000/metrics'
kubectl run m --rm -i --restart=Never -n online-library --image=curlimages/curl -- curl -s http://online-library-backend:5000/metrics | Select-String 'http_request' | Select-Object -First 20
Shot '7.4' 'термінал: рядки http_requests_total{...} і http_request_duration_seconds_bucket{...}'
Start-Process 'http://localhost:9090/targets'
Ask 'У Prometheus знайдіть ціль serviceMonitor/online-library/online-library-backend/0 (розгорніть її)'
Shot '7.5' 'браузер Prometheus: Target health, ціль backend — 5 ендпоінтів UP'
Start-Sleep -Seconds 30
Start-Process 'http://localhost:9090/query?g0.expr=sum%20by%20(status)%20(rate(http_requests_total%7Bnamespace%3D%22online-library%22%7D%5B1m%5D))&g0.tab=graph&g0.range_input=15m'
Shot '7.6' 'браузер Prometheus: запит sum by (status) (rate(http_requests_total...)) і графік'

Say '4. Логи (п.3)'
Run 'kubectl logs -n online-library -l app.kubernetes.io/component=backend --tail=5'
Shot '7.7' 'термінал: рядки логів у JSON (time, level, msg, method, route, status, duration_ms)'

Say '5. Дашборд з Git (п.4)'
Run 'kubectl get configmap -A -l grafana_dashboard=1'
Start-Process 'http://localhost:3000/d/online-library'
Ask 'У Grafana вгорі праворуч: діапазон Last 15 minutes, автооновлення 10s'
Shot '7.9' 'термінал з ConfigMap + браузер: дашборд «Онлайн бібліотека»'

Say '6. Навантаження на дашборді (п.5)'
Run 'kubectl scale deployment load --replicas=3'
kubectl delete pod hey --ignore-not-found *> $null
Open-Window 'kubectl run hey --rm -it --restart=Never --image=williamyeh/hey -- -z 3m -c 20 http://online-library-frontend.online-library.svc/api/books'
Write-Host '  Чекаю 2 хв, поки графіки підростуть...' -ForegroundColor Gray
Start-Sleep -Seconds 120
Shot '7.10' 'браузер: дашборд під навантаженням — ріст «Запити за секунду», p95 і CPU'

Say '7. Ще одна зміна через Git: масштабування 5 -> 8 (п.5)'
EditFile $Values 's/^  replicaCount: 5$/  replicaCount: 8/'
Run 'git --no-pager diff'
CommitPush 'scale backend 5 -> 8'
Refresh 'online-library'
WaitFor '8 подів backend готові' {
    "$(kubectl get rollout online-library-backend -n online-library -o 'jsonpath={.status.availableReplicas}' 2>$null)" -eq '8'
} 600
Start-Sleep -Seconds 60
Run 'kubectl get pods -n online-library -l app.kubernetes.io/component=backend'
Shot '7.11' 'термінал: 8 подів backend + браузер: нові лінії на панелях CPU і пам''яті'
Run 'git revert --no-edit HEAD'
Run 'git push'
Refresh 'online-library'
WaitFor 'знову 5 подів' {
    "$(kubectl get rollout online-library-backend -n online-library -o 'jsonpath={.spec.replicas}' 2>$null)" -eq '5'
} 300

Say '8. Хороший реліз 2.1.0: аналіз Successful (п.6a)'
Open-WatchWindow
EditFile $Values 's/^(    tag: .)2\.0\.0/\12.1.0/'
Run 'git --no-pager diff'
CommitPush 'release 2.1.0'
Refresh 'online-library'
WaitFor 'AnalysisRun Successful і реліз завершено (2–4 хв)' {
    $phases = "$(kubectl get analysisrun -n online-library -o 'jsonpath={.items[*].status.phase}' 2>$null)"
    ($phases -match 'Successful') -and ((RolloutPhase) -eq 'Healthy')
} 900
Run 'kubectl get analysisrun -n online-library'
Shot '7.12' 'термінал: AnalysisRun Successful + вікно стану Rollout Healthy на 2.1.0'

Say '9. Поганий реліз: FAIL_RATE=0.5 -> автоматичний abort (п.6b–c)'
EditFile $Values '/FAIL_RATE/{n;s/(value: .)0(.)$/\10.5\2/}'
Run 'git --no-pager diff'
CommitPush 'bad release: FAIL_RATE=0.5'
Refresh 'online-library'
WaitFor 'аналіз провалився і Rollout відкотився (Degraded), ~2 хв' { (RolloutPhase) -eq 'Degraded' } 900
Run 'kubectl get analysisrun -n online-library'
Shot '7.13' 'вікно стану Rollout: Degraded, AnalysisRun з ✖, 5 подів stable'
$failed = (kubectl get analysisrun -n online-library -o json | ConvertFrom-Json).items | Where-Object { $_.status.phase -eq 'Failed' } | Select-Object -Last 1
if ($failed) { Run "kubectl describe analysisrun $($failed.metadata.name) -n online-library" }
Shot '7.14' 'термінал: describe analysisrun — Measurements із значеннями ~0.9, Phase Failed'
Start-Process 'http://localhost:3000/d/online-library'
Shot '7.15' 'браузер: дашборд — сплеск «Частка помилок 5xx», «5xx по подах» лише з одного пода'
Start-Process 'http://localhost:3000/explore'
Ask 'Grafana Explore: зверху джерело Loki -> праворуч перемкніть Code -> запит  {namespace="online-library"} | json | status >= 500  -> Run query -> клацніть на рядок (видно мітку pod)'
Shot '7.8 і 7.16' 'браузер: Loki, рядки зі status 500 — усі з одного (canary) пода'

Say '10. Завершення відкату через Git'
Run 'git revert --no-edit HEAD'
Run 'git push'
Refresh 'online-library'
WaitFor 'Rollout Healthy і Argo CD Synced / Healthy' { ((RolloutPhase) -eq 'Healthy') -and ((AppStatus 'online-library') -eq 'Synced/Healthy') } 600
Run 'git --no-pager log --oneline -6'
Start-Process 'https://localhost:8443/applications/argocd/online-library'
Shot '7.17' 'термінал з git log (Revert "bad release...") + браузер Argo CD Synced / Healthy'

Write-Host ''
Write-Host 'Рисунок 7.18 (алерт Firing) — за бажанням, вручну за docs/LAB7.md п.2.8; інакше видаліть його зі звіту.' -ForegroundColor Gray
Say 'ЛР-7 завершено'
