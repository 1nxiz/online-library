# ЛР-10. Моніторинг продуктивності в Amazon CloudWatch (LocalStack) — покроковий скрипт зі скріншотами.
# Запуск з кореня репозиторію (гілка lab10):
#   powershell -ExecutionPolicy Bypass -File scripts\lab10.ps1
. "$PSScriptRoot\aws-common.ps1"
Start-AwsLab 'lab10'

$Lb = 'http://localhost:8080'
$Ns = 'OnlineLibrary'
$Dim = 'Name=Service,Value=online-library'
$PhaseSeconds = 150   # тривалість кожної фази навантаження (2,5 хв — щоб Alarm встиг оцінити 1-2 періоди по 60 с)
$script:Phases = @()
New-Item -ItemType Directory -Force "$AwsDir\out" | Out-Null

function UtcNow { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function AlarmStates {
    aws cloudwatch describe-alarms --alarm-name-prefix library- `
        --query 'MetricAlarms[].[AlarmName,StateValue,MetricName,Statistic,Threshold]' --output table
}

function AlarmState($name) {
    "$(aws cloudwatch describe-alarms --alarm-names $name --query 'MetricAlarms[0].StateValue' --output text)".Trim()
}

function Wait-Apps {
    foreach ($a in 'app1', 'app2', 'app3') {
        WaitFor "$a healthy" { "$(docker inspect -f '{{.State.Health.Status}}' $a 2>$null)".Trim() -eq 'healthy' } 180
    }
}

# Перезапуск екземплярів з новими FAIL_RATE / DELAY_MS (docker compose перестворює контейнери)
function Set-Fault($failRate, $delayMs) {
    $env:FAIL_RATE = "$failRate"
    $env:DELAY_MS = "$delayMs"
    Show "`$env:FAIL_RATE='$failRate'; `$env:DELAY_MS='$delayMs'; docker compose -f aws/docker-compose.yml up -d app1 app2 app3"
    dc up -d app1 app2 app3
    Wait-Apps
}

# Фаза експерименту: кероване навантаження hey у фоні + очікування стану Alarm
function Run-Phase($name, $title, $alarm = $null, $wantState = $null) {
    Say "Фаза '$title': $PhaseSeconds с навантаження (5 клієнтів, до 50 запитів/с)"
    docker rm -f load *> $null
    $start = UtcNow
    Show "docker run -d --name load --network library-aws williamyeh/hey -z ${PhaseSeconds}s -c 5 -q 10 http://nginx/books"
    docker run -d --name load --network library-aws williamyeh/hey -z "${PhaseSeconds}s" -c 5 -q 10 http://nginx/books | Out-Null
    if ($alarm) {
        WaitFor "Alarm $alarm -> $wantState (CloudWatch оцінює раз на хвилину)" { (AlarmState $alarm) -eq $wantState } ($PhaseSeconds + 120)
    }
    Write-Host '  ... чекаю завершення навантаження' -ForegroundColor Gray
    docker wait load | Out-Null
    $script:Phases += [pscustomobject]@{ name = $name; start = $start; end = (UtcNow) }
    Set-Content -Encoding UTF8 "$AwsDir\out\phases.json" (ConvertTo-Json -InputObject @($script:Phases))
    Show 'docker logs load   (підсумок hey)'
    docker logs load | Select-String 'Requests/sec|Average:|Slowest:|Fastest:|\[200\]|\[500\]'
    docker rm load *> $null
    AlarmStates
}

Say '1. Код: збір метрик, PutMetricData, аналіз (п.2, п.3)'
Run 'code aws/app/metrics.py aws/app/server.py aws/cloudwatch/analyze.py aws/docker-compose.yml'
Shot '10.1' 'VS Code: metrics.py (Requests, Errors, Latency -> put_metric_data) і server.py (FAIL_RATE, DELAY_MS, metrics.record)'

Say '2. Запуск: LocalStack (CloudWatch) + 3 екземпляри + nginx (п.1)'
Remove-Item "$AwsDir\out\phases.json" -ErrorAction SilentlyContinue
$env:FAIL_RATE = '0'; $env:DELAY_MS = '0'
Run 'docker compose -f aws/docker-compose.yml up -d --build'
WaitFor 'LocalStack готовий' { LocalStackHealthy } 900
Wait-Apps
Run 'docker compose -f aws/docker-compose.yml ps --format "table {{.Name}}\t{{.Status}}"'
Show 'Invoke-RestMethod http://localhost:4566/_localstack/health  (сервіс cloudwatch)'
(Invoke-RestMethod 'http://localhost:4566/_localstack/health').services | Select-Object cloudwatch, dynamodb, logs | Format-List
AwsRun cloudwatch describe-alarms --output table
Shot '10.2' 'термінал: контейнери запущені, cloudwatch: available, AWS CLI звертається до CloudWatch API (поки без Alarm)'

Say '3. Застосунок публікує метрики (PutMetricData кожні 10 с) (п.2, п.3)'
$book = '{"title":"Кобзар","author":"Тарас Шевченко","year":1840}'
Invoke-RestMethod -Method POST -Uri "$Lb/books" -Body $book -ContentType 'application/json' | Out-Null
Show "1..40 | % { Invoke-WebRequest $Lb/books }"
1..40 | ForEach-Object { Api 'GET' "$Lb/books" | Out-Null }
Write-Host '  Чекаю 15 с — фоновий потік надсилає накопичене в CloudWatch' -ForegroundColor Gray
Start-Sleep -Seconds 15
Run 'docker logs app1 --tail 5'
AwsRun cloudwatch list-metrics --namespace $Ns --output table
Shot '10.3' 'термінал: у лозі app1 "metrics published", list-metrics показує Requests, Errors, Latency у просторі OnlineLibrary'

Say '4. PutMetricData вручну і читання через GetMetricStatistics (п.3, п.4)'
$t = UtcNow
AwsRun cloudwatch put-metric-data --namespace $Ns --metric-name ManualCheck --unit Count --value 1 --dimensions $Dim
$from = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
$to = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
AwsRun cloudwatch get-metric-statistics --namespace $Ns --metric-name Requests --dimensions $Dim `
    --start-time $from --end-time $to --period 60 --statistics Sum --output table
AwsRun cloudwatch get-metric-statistics --namespace $Ns --metric-name Latency --dimensions $Dim `
    --start-time $from --end-time $to --period 60 --statistics Average Maximum SampleCount --output table
Shot '10.4' 'термінал: put-metric-data без помилок; get-metric-statistics — Sum запитів і Average/Maximum Latency за хвилини'

Say '5. CloudWatch Alarm на порогові значення (п.6)'
AwsRun cloudwatch put-metric-alarm --alarm-name library-high-errors `
    --alarm-description Errors-Sum-over-10-per-minute `
    --namespace $Ns --metric-name Errors --dimensions $Dim --statistic Sum --period 60 `
    --evaluation-periods 1 --threshold 10 --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching
AwsRun cloudwatch put-metric-alarm --alarm-name library-high-latency `
    --alarm-description Latency-Average-over-300ms `
    --namespace $Ns --metric-name Latency --dimensions $Dim --statistic Average --period 60 `
    --evaluation-periods 1 --threshold 300 --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching
WaitFor 'Alarm отримали початковий стан' { (AlarmState 'library-high-errors') -ne 'INSUFFICIENT_DATA' } 150
AlarmStates
Shot '10.5' 'термінал: створено library-high-errors (Errors Sum > 10) і library-high-latency (Latency Average > 300), стан OK'

Say '6. Експеримент: звичайне навантаження -> помилки -> затримки -> відновлення (п.7)'
Run-Phase 'normal' 'звичайне навантаження'
Shot '10.6' 'термінал: hey — лише [200], середній час кілька мс; обидва Alarm у стані OK'

Set-Fault '0.3' '0'
Run-Phase 'errors' 'помилки 30% (FAIL_RATE=0.3)' 'library-high-errors' 'ALARM'
Shot '10.7' 'термінал: hey показує [500]; library-high-errors перейшов у ALARM'

Set-Fault '0' '400'
Run-Phase 'latency' 'затримка 400 мс (DELAY_MS=400)' 'library-high-latency' 'ALARM'
Shot '10.8' 'термінал: середній час hey ~0.4 с; library-high-latency у ALARM, library-high-errors повернувся в OK'

Set-Fault '0' '0'
Run-Phase 'recovery' 'відновлення' 'library-high-latency' 'OK'
Shot '10.9' 'термінал: знову лише [200] і швидкі відповіді; обидва Alarm у стані OK'

Say '7. Історія спрацювань Alarm'
AwsRun cloudwatch describe-alarm-history --alarm-name library-high-errors --history-item-type StateUpdate `
    --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output table
AwsRun cloudwatch describe-alarm-history --alarm-name library-high-latency --history-item-type StateUpdate `
    --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output table
Shot '10.10' 'термінал: історія переходів OK -> ALARM -> OK для обох Alarm з часом'

Say '8. Аналіз: GetMetricData + обчислення показників (п.4, п.5)'
Run 'docker compose -f aws/docker-compose.yml --profile tools run --rm analyze --minutes 20'
Shot '10.11' 'термінал: таблиця по хвилинах (запитів, запит/с, частка помилок, середній час) і підсумки по фазах'

Say '9. Графіки (п.8)'
Run 'Start-Process aws\out\lab10-metrics.png'
Shot '10.12' 'графік lab10-metrics.png: запити, помилки з порогом Alarm, час відповіді; кольорові смуги — фази експерименту'

Say 'ЛР-10 завершено. Результати: aws\out\lab10-metrics.png, lab10-metrics.csv, lab10-summary.json'
Write-Host 'Зупинити все: docker compose -f aws/docker-compose.yml down' -ForegroundColor Gray
