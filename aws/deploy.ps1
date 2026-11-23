# ЛР-8: автоматичне розгортання serverless-застосунку в LocalStack за допомогою AWS CLI.
# Створює (або перестворює) таблицю DynamoDB, роль IAM, Lambda-функцію і REST API в API Gateway.
#
# Запуск із кореня репозиторію (LocalStack уже запущений: docker compose -f aws/docker-compose.yml up -d):
#   powershell -ExecutionPolicy Bypass -File aws\deploy.ps1
#
# AWS CLI запускається в Docker (образ amazon/aws-cli), тож встановлювати його в Windows не обов'язково.
# Якщо AWS CLI встановлено локально, ті самі команди працюють з --endpoint-url http://localhost:4566.

# Continue: очікувані помилки AWS CLI ("ще не існує") перевіряємо через $LASTEXITCODE
$ErrorActionPreference = 'Continue'
$AwsDir = $PSScriptRoot
$Region = 'us-east-1'
$Account = '000000000000'          # фіксований номер акаунта LocalStack
$Table = 'Books'
$Function = 'books'
$ApiName = 'books-api'
$Stage = 'dev'

function aws {
    docker run --rm -i --network library-aws -v "${AwsDir}:/aws" `
        -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=$Region `
        amazon/aws-cli:2.15.0 --endpoint-url http://localstack:4566 @args
}

function Step($text) { Write-Host ''; Write-Host "--- $text" -ForegroundColor Cyan }

function Check($what) {
    if ($LASTEXITCODE -ne 0) { throw "Помилка на кроці: $what" }
}

Step '0. LocalStack доступний?'
$ok = $false
foreach ($i in 1..60) {
    try {
        $health = Invoke-RestMethod -Uri 'http://localhost:4566/_localstack/health' -TimeoutSec 3
        if ("$($health.services.lambda)" -match 'available|running') { $ok = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $ok) { throw 'LocalStack не відповідає. Запустіть: docker compose -f aws/docker-compose.yml up -d' }
Write-Host "LocalStack $($health.version): lambda=$($health.services.lambda) dynamodb=$($health.services.dynamodb) apigateway=$($health.services.apigateway)"

Step '1. Пакування коду Lambda -> aws/build/books.zip'
New-Item -ItemType Directory -Force "$AwsDir\build" | Out-Null
Compress-Archive -Path "$AwsDir\lambda\handler.py" -DestinationPath "$AwsDir\build\books.zip" -Force
Get-Item "$AwsDir\build\books.zip" | Select-Object Name, Length

Step "2. Таблиця DynamoDB '$Table' (ключ id)"
aws dynamodb describe-table --table-name $Table *> $null
if ($LASTEXITCODE -ne 0) {
    aws dynamodb create-table --table-name $Table `
        --attribute-definitions 'AttributeName=id,AttributeType=S' `
        --key-schema 'AttributeName=id,KeyType=HASH' `
        --billing-mode PAY_PER_REQUEST --output text --query 'TableDescription.TableStatus'
    Check 'create-table'
    aws dynamodb wait table-exists --table-name $Table
} else {
    Write-Host "таблиця $Table уже існує — залишаємо дані"
}

Step '3. Роль IAM для Lambda'
aws iam get-role --role-name lambda-books-role *> $null
if ($LASTEXITCODE -ne 0) {
    aws iam create-role --role-name lambda-books-role `
        --assume-role-policy-document file://iam/trust-policy.json --query 'Role.Arn' --output text
    Check 'create-role'
}
$RoleArn = "arn:aws:iam::${Account}:role/lambda-books-role"

Step "4. Lambda-функція '$Function' (python3.12)"
aws lambda get-function --function-name $Function *> $null
if ($LASTEXITCODE -eq 0) {
    aws lambda update-function-code --function-name $Function --zip-file fileb://build/books.zip --query 'LastUpdateStatus' --output text
    Check 'update-function-code'
    aws lambda wait function-updated-v2 --function-name $Function
} else {
    aws lambda create-function --function-name $Function `
        --runtime python3.12 --handler handler.lambda_handler `
        --zip-file fileb://build/books.zip --role $RoleArn `
        --timeout 30 --memory-size 256 `
        --environment "Variables={TABLE_NAME=$Table}" `
        --query 'FunctionArn' --output text
    Check 'create-function'
}
aws lambda wait function-active-v2 --function-name $Function
Check 'wait function-active'
$FunctionArn = "arn:aws:lambda:${Region}:${Account}:function:$Function"

Step "5. REST API '$ApiName' в API Gateway"
$old = aws apigateway get-rest-apis --query "items[?name=='$ApiName'].id" --output text
foreach ($id in ("$old" -split '\s+' | Where-Object { $_ })) {
    Write-Host "видаляю старий API $id"
    aws apigateway delete-rest-api --rest-api-id $id
}
$ApiId = "$(aws apigateway create-rest-api --name $ApiName --query id --output text)".Trim()
Check 'create-rest-api'
$RootId = "$(aws apigateway get-resources --rest-api-id $ApiId --query "items[?path=='/'].id" --output text)".Trim()
$BooksId = "$(aws apigateway create-resource --rest-api-id $ApiId --parent-id $RootId --path-part books --query id --output text)".Trim()
$BookId = "$(aws apigateway create-resource --rest-api-id $ApiId --parent-id $BooksId --path-part '{id}' --query id --output text)".Trim()
$HealthId = "$(aws apigateway create-resource --rest-api-id $ApiId --parent-id $RootId --path-part health --query id --output text)".Trim()
Write-Host "API $ApiId : / = $RootId, /books = $BooksId, /books/{id} = $BookId, /health = $HealthId"

$Uri = "arn:aws:apigateway:${Region}:lambda:path/2015-03-31/functions/$FunctionArn/invocations"
foreach ($res in @($BooksId, $BookId, $HealthId)) {
    # будь-який метод (ANY) -> проксі-інтеграція з Lambda (AWS_PROXY)
    aws apigateway put-method --rest-api-id $ApiId --resource-id $res --http-method ANY --authorization-type NONE --query httpMethod --output text
    Check 'put-method'
    aws apigateway put-integration --rest-api-id $ApiId --resource-id $res --http-method ANY `
        --type AWS_PROXY --integration-http-method POST --uri $Uri --query type --output text
    Check 'put-integration'
}

Step '6. Дозвіл API Gateway викликати Lambda'
aws lambda remove-permission --function-name $Function --statement-id apigw-invoke *> $null
aws lambda add-permission --function-name $Function --statement-id apigw-invoke `
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com `
    --source-arn "arn:aws:execute-api:${Region}:${Account}:$ApiId/*/*/*" --query Statement --output text | Out-Null
Check 'add-permission'

Step "7. Публікація API (stage '$Stage')"
aws apigateway create-deployment --rest-api-id $ApiId --stage-name $Stage --query id --output text
Check 'create-deployment'

$BaseUrl = "http://localhost:4566/restapis/$ApiId/$Stage/_user_request_"
Set-Content -Encoding ascii "$AwsDir\build\api-url.txt" $BaseUrl
Write-Host ''
Write-Host 'Готово. Базова адреса API:' -ForegroundColor Green
Write-Host "  $BaseUrl" -ForegroundColor Green
Write-Host "  GET    $BaseUrl/health"
Write-Host "  GET    $BaseUrl/books"
Write-Host "  POST   $BaseUrl/books"
Write-Host "  GET    $BaseUrl/books/{id}"
Write-Host "  DELETE $BaseUrl/books/{id}"
