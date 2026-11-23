# ЛР-9. Балансування навантаження: 3 екземпляри застосунку за nginx — покроковий скрипт зі скріншотами.
# Запуск з кореня репозиторію (гілка lab9):
#   powershell -ExecutionPolicy Bypass -File scripts\lab9.ps1
. "$PSScriptRoot\aws-common.ps1"
Start-AwsLab 'lab9'

$Lb = 'http://localhost:8080'      # єдина точка входу (nginx)
$Direct = 'http://localhost:8001'  # app1 напряму, без балансувальника
$script:Summary = @()
New-Item -ItemType Directory -Force "$AwsDir\out" | Out-Null

# N запитів GET: розподіл між екземплярами, помилки, середній час
function Measure-Requests($label, $url, $n = 30) {
    Show "$n x GET $url"
    $results = @(1..$n | ForEach-Object { Api 'GET' $url $null 5 })
    $ok = @($results | Where-Object { $_.Status -eq 200 })
    $errors = $n - $ok.Count
    $avg = 0
    if ($ok.Count -gt 0) { $avg = [int](($ok | Measure-Object -Property Ms -Average).Average) }
    $groups = @($ok | Group-Object Instance | Sort-Object Name)
    foreach ($g in $groups) {
        Write-Host ('  {0,-6} {1,3}  {2}' -f $g.Name, $g.Count, ('#' * $g.Count)) -ForegroundColor Green
    }
    if ($errors -gt 0) { Write-Host ('  {0,-6} {1,3}  {2}' -f 'ERROR', $errors, ('x' * $errors)) -ForegroundColor Red }
    $dist = ($groups | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-Host "  успішно: $($ok.Count)/$n, помилок: $errors, середній час: $avg мс"
    $script:Summary += [pscustomobject]@{
        'Сценарій' = $label; 'Запитів' = $n; 'Успішно' = $ok.Count; 'Помилок' = $errors
        'Розподіл' = $dist; 'Сер. час, мс' = $avg
    }
}

function Wait-Healthy($name) {
    WaitFor "$name healthy" { "$(docker inspect -f '{{.State.Health.Status}}' $name 2>$null)".Trim() -eq 'healthy' } 180
}

Say '1. Контейнерна версія застосунку з ЛР-8 і балансувальник (п.1, п.3)'
Run 'code aws/app/server.py aws/app/Dockerfile aws/nginx/nginx.conf aws/docker-compose.yml'
Shot '9.1' 'VS Code: aws/app/Dockerfile і server.py (той самий handler.py), nginx.conf з upstream на 3 екземпляри'

Say '2. Запуск: LocalStack + app1, app2, app3 + nginx (п.2)'
Run 'docker compose -f aws/docker-compose.yml up -d --build'
WaitFor 'LocalStack готовий' { LocalStackHealthy } 900
foreach ($a in 'app1', 'app2', 'app3') { Wait-Healthy $a }
WaitFor 'nginx відповідає' { (Api 'GET' "$Lb/lb-status").Status -eq 200 } 120
Run 'docker compose -f aws/docker-compose.yml ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
Shot '9.2' 'термінал: localstack, app1, app2, app3 (healthy) і nginx з портом 8080'

Say '3. /health і ідентифікатор екземпляра (п.2, п.4)'
foreach ($i in 1..3) { Show "Invoke-RestMethod $Lb/health"; Invoke-RestMethod -Uri "$Lb/health" | Format-Table -AutoSize }
Run "curl.exe -s -i $Lb/health"
Write-Host ''
Shot '9.3' 'термінал: /health тричі (instance app1/app2/app3) і curl -i із заголовками X-Instance та X-Upstream'

Say '4. Розподіл запитів між екземплярами (п.5)'
Measure-Requests 'nginx, 3 екземпляри' "$Lb/health" 30
Shot '9.4' 'термінал: 30 запитів через nginx — приблизно порівну app1 / app2 / app3, 0 помилок'

Say '5. Вивести один екземпляр із роботи (п.6)'
Run 'docker compose -f aws/docker-compose.yml stop app2'
Run 'docker compose -f aws/docker-compose.yml ps --format "table {{.Name}}\t{{.Status}}"'
Measure-Requests 'nginx, app2 зупинено' "$Lb/health" 30
Shot '9.5' 'термінал: app2 зупинено; запити йдуть лише на app1 і app3, помилок 0'
Run 'docker logs nginx --tail 12'
Shot '9.6' 'термінал: лог nginx — upstream=…:8000 лише app1/app3; для першого запиту видно спробу app2 і перехід на наступний'

Say '6. Відновити екземпляр (п.7)'
Run 'docker compose -f aws/docker-compose.yml start app2'
Wait-Healthy 'app2'
Write-Host '  Чекаю 12 с (fail_timeout=10s), щоб nginx повернув app2 у ротацію...' -ForegroundColor Gray
Start-Sleep -Seconds 12
Measure-Requests 'nginx, app2 відновлено' "$Lb/health" 30
Shot '9.7' 'термінал: app2 знову отримує запити — розподіл на 3 екземпляри'

Say '7. Спільні дані: екземпляри без стану (stateless)'
$book = '{"title":"\u041a\u043e\u0431\u0437\u0430\u0440","author":"\u0422\u0430\u0440\u0430\u0441 \u0428\u0435\u0432\u0447\u0435\u043d\u043a\u043e","year":1840}'
Show "Invoke-RestMethod -Method POST $Lb/books"
$created = Invoke-RestMethod -Method POST -Uri "$Lb/books" -Body $book -ContentType 'application/json'
$created | Format-List id, title, author
foreach ($i in 1..3) {
    $r = Api 'GET' "$Lb/books/$($created.id)"
    Write-Host "  GET /books/$($created.id) -> HTTP $($r.Status), обробив $($r.Instance)"
}
Shot '9.8' 'термінал: книгу створено через nginx, її повертають різні екземпляри (дані в спільній DynamoDB)'

Say '8. Порівняння: з балансуванням і без (п.8)'
Measure-Requests 'напряму app1, всі живі' "$Direct/health" 30
Run 'docker compose -f aws/docker-compose.yml stop app1'
Measure-Requests 'напряму app1, app1 зупинено' "$Direct/health" 20
Measure-Requests 'nginx, app1 зупинено' "$Lb/health" 30
Shot '9.9' 'термінал: без балансувальника всі запити на app1, після його зупинки — 100% помилок; через nginx — 0 помилок'
Run 'docker compose -f aws/docker-compose.yml start app1'
Wait-Healthy 'app1'
Start-Sleep -Seconds 12

Say '9. Навантажувальний тест: nginx (3 екземпляри) проти одного app1'
Show 'docker run --rm --network library-aws williamyeh/hey -n 3000 -c 30 http://nginx/health'
docker run --rm --network library-aws williamyeh/hey -n 3000 -c 30 http://nginx/health | Select-String 'Requests/sec|Average:|Slowest:|\[200\]|\[5'
Show 'docker run --rm --network library-aws williamyeh/hey -n 3000 -c 30 http://app1:8000/health'
docker run --rm --network library-aws williamyeh/hey -n 3000 -c 30 http://app1:8000/health | Select-String 'Requests/sec|Average:|Slowest:|\[200\]|\[5'
Shot '9.10' 'термінал: hey — Requests/sec і середня затримка через nginx та напряму в один екземпляр'

Say '10. Підсумкова таблиця (п.8)'
$script:Summary | Format-Table -AutoSize
$script:Summary | Export-Csv -NoTypeInformation -Encoding UTF8 "$AwsDir\out\lab9-results.csv"
Write-Host "  Збережено: aws\out\lab9-results.csv" -ForegroundColor Gray
Shot '9.11' 'термінал: таблиця всіх сценаріїв (розподіл, помилки, середній час)'

Say 'ЛР-9 завершено. Контейнери працюють (зупинити: docker compose -f aws/docker-compose.yml down)'
Write-Host 'Наступна: git checkout lab10; git pull; powershell -ExecutionPolicy Bypass -File scripts\lab10.ps1' -ForegroundColor Gray
