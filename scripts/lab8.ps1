# ЛР-8. Serverless у LocalStack: Lambda + API Gateway + DynamoDB — покроковий скрипт зі скріншотами.
# Запуск з кореня репозиторію (гілка lab8):
#   powershell -ExecutionPolicy Bypass -File scripts\lab8.ps1
. "$PSScriptRoot\aws-common.ps1"
Start-AwsLab 'lab8'

Say '1. Код застосунку і структура (п.2, п.8)'
Run 'code aws/lambda/handler.py aws/deploy.ps1 aws/docker-compose.yml'
Shot '8.1' 'VS Code: зліва папка aws/ (lambda, iam, deploy.ps1, docker-compose.yml), відкритий handler.py'

Say '2. LocalStack (п.1)'
Start-LocalStack
Run 'docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
Show 'Invoke-RestMethod http://localhost:4566/_localstack/health'
$h = Invoke-RestMethod -Uri 'http://localhost:4566/_localstack/health'
Write-Host "version: $($h.version)"
$h.services | Format-List lambda, apigateway, dynamodb, iam, logs, cloudwatch
Shot '8.2' 'термінал: контейнер localstack (4.14.0) Up/healthy і список сервісів available'

Say '3. AWS CLI, налаштований на LocalStack (п.1)'
AwsRun --version
AwsRun sts get-caller-identity
Shot '8.3' 'термінал: версія aws-cli і get-caller-identity з акаунтом 000000000000 (LocalStack)'

Say '4. Автоматичне розгортання сценарієм AWS CLI (п.2–4, п.7)'
Run 'powershell -ExecutionPolicy Bypass -File aws\deploy.ps1'
$Base = "$(Get-Content "$AwsDir\build\api-url.txt")".Trim()
Shot '8.4' 'термінал: вивід aws\deploy.ps1 — кроки 0–7 і «Готово. Базова адреса API»'

Say '5. Створені ресурси (п.2–4)'
AwsRun dynamodb describe-table --table-name Books --query 'Table.{Name:TableName,Key:KeySchema[0].AttributeName,Status:TableStatus,Billing:BillingModeSummary.BillingMode}' --output table
AwsRun lambda list-functions --query 'Functions[].{Name:FunctionName,Runtime:Runtime,Handler:Handler,State:State}' --output table
$apiId = ($Base -split '/')[4]
AwsRun apigateway get-resources --rest-api-id $apiId --query 'items[].{Path:path,Methods:join(`,`,keys(resourceMethods||`{}`))}' --output table
Shot '8.5' 'термінал: таблиця Books, функція books (python3.12, Active), ресурси API /books, /books/{id}, /health з методом ANY'

Say '6. Перевірка HTTP API (п.5–6)'
Write-Host '  Перший виклик Lambda довгий (LocalStack завантажує образ python3.12) — до 1–2 хв' -ForegroundColor Gray
Show "Invoke-RestMethod $Base/health"
WaitFor 'Lambda відповідає на /health' { (Api 'GET' "$Base/health" $null 120).Status -eq 200 } 300
Invoke-RestMethod -Uri "$Base/health" | Format-List

# JSON з \u-послідовностями: лише ASCII, тому не залежить від кодування Windows PowerShell
$book1 = '{"title":"\u041a\u043e\u0431\u0437\u0430\u0440","author":"\u0422\u0430\u0440\u0430\u0441 \u0428\u0435\u0432\u0447\u0435\u043d\u043a\u043e","year":1840}'
$book2 = '{"title":"\u041b\u0456\u0441\u043e\u0432\u0430 \u043f\u0456\u0441\u043d\u044f","author":"\u041b\u0435\u0441\u044f \u0423\u043a\u0440\u0430\u0457\u043d\u043a\u0430","year":1911}'
Show "Invoke-RestMethod -Method POST $Base/books -Body <Кобзар>"
$b1 = Invoke-RestMethod -Method POST -Uri "$Base/books" -Body $book1 -ContentType 'application/json'
$b1 | Format-List
Show "Invoke-RestMethod -Method POST $Base/books -Body <Лісова пісня>"
$b2 = Invoke-RestMethod -Method POST -Uri "$Base/books" -Body $book2 -ContentType 'application/json'
$b2 | Format-List
Shot '8.6' 'термінал: /health -> ok і дві створені книги (201) з id, title, author, year'

Show "Invoke-RestMethod $Base/books"
Invoke-RestMethod -Uri "$Base/books" | Format-Table id, title, author, year, available -AutoSize
Show "Invoke-RestMethod $Base/books/$($b1.id)"
Invoke-RestMethod -Uri "$Base/books/$($b1.id)" | Format-List
Shot '8.7' 'термінал: список книг (GET /books) і одна книга за id (GET /books/{id})'

Show "Invoke-WebRequest -Method DELETE $Base/books/$($b2.id)"
$del = Api 'DELETE' "$Base/books/$($b2.id)"
Write-Host "  DELETE -> HTTP $($del.Status)"
$again = Api 'GET' "$Base/books/$($b2.id)"
Write-Host "  GET видаленої книги -> HTTP $($again.Status)"
$bad = Api 'POST' "$Base/books" '{"title":"","author":"X"}'
Write-Host "  POST без назви -> HTTP $($bad.Status)"
Shot '8.8' 'термінал: DELETE -> 204, повторний GET -> 404, некоректний POST -> 400'

Say '7. HTTP-клієнт curl (п.6)'
Set-Content -Encoding ascii "$AwsDir\build\book3.json" '{"title":"\u0422\u0456\u043d\u0456 \u0437\u0430\u0431\u0443\u0442\u0438\u0445 \u043f\u0440\u0435\u0434\u043a\u0456\u0432","author":"\u041c\u0438\u0445\u0430\u0439\u043b\u043e \u041a\u043e\u0446\u044e\u0431\u0438\u043d\u0441\u044c\u043a\u0438\u0439","year":1911}'
Run "curl.exe -s -i -X POST -H 'Content-Type: application/json' --data-binary '@aws/build/book3.json' $Base/books"
Write-Host ''
Run "curl.exe -s -i $Base/health"
Write-Host ''
Shot '8.9' 'термінал: curl -i — статус HTTP/1.1 201 і 200, заголовки Content-Type та X-Instance, тіло JSON'

Say '8. Дані в DynamoDB і логи Lambda'
AwsRun dynamodb scan --table-name Books --query 'Items[].{id:id.S,title:title.S,year:year.N}' --output table
Shot '8.10' 'термінал: aws dynamodb scan — записи книг лежать у таблиці Books'
AwsRun logs filter-log-events --log-group-name /aws/lambda/books --limit 8 --query 'events[].message' --output text
Shot '8.11' 'термінал: логи Lambda (CloudWatch Logs) з JSON-рядками method / path / status'

Say 'ЛР-8 завершено. LocalStack лишається запущеним (зупинити: docker compose -f aws/docker-compose.yml down)'
Write-Host 'Наступна: git checkout lab9; git pull; powershell -ExecutionPolicy Bypass -File scripts\lab9.ps1' -ForegroundColor Gray
