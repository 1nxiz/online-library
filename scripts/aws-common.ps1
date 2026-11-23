# Спільні функції для ЛР-8, ЛР-9, ЛР-10 (LocalStack + Docker).
# Підключає scripts\common.ps1 (Say, Run, Shot, Ask, WaitFor, EditFile, CommitPush).
. "$PSScriptRoot\common.ps1"

$AwsDir = "$Repo\aws"
$AwsImage = 'amazon/aws-cli:2.15.0'

# docker compose для aws/docker-compose.yml
function dc {
    docker compose -f "$Repo\aws\docker-compose.yml" @args
}

# AWS CLI у Docker, спрямований на LocalStack (у мережі library-aws)
function aws {
    docker run --rm -i --network library-aws -v "${AwsDir}:/aws" `
        -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
        $AwsImage --endpoint-url http://localstack:4566 @args
}

# Показати команду AWS CLI так, як її набрали б вручну, і виконати
function AwsRun {
    Show ('aws --endpoint-url http://localhost:4566 ' + ($args -join ' '))
    aws @args
}

function LocalStackHealthy {
    try {
        $h = Invoke-RestMethod -Uri 'http://localhost:4566/_localstack/health' -TimeoutSec 3
        return ("$($h.services.dynamodb)" -match 'available|running')
    } catch {
        return $false
    }
}

# HTTP-запит: повертає Status, Instance (заголовок X-Instance), Ms і Body
function Api($method, $url, $body = $null, $timeout = 10) {
    $start = Get-Date
    $params = @{ Uri = $url; Method = $method; UseBasicParsing = $true; TimeoutSec = $timeout }
    if ($body) { $params.Body = $body; $params.ContentType = 'application/json' }
    $status = 0; $instance = '-'; $content = ''
    try {
        $r = Invoke-WebRequest @params
        $status = [int]$r.StatusCode
        $instance = "$($r.Headers['X-Instance'])"
        $content = $r.Content
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $status = [int]$resp.StatusCode
            $instance = "$($resp.Headers['X-Instance'])"
        }
    }
    $ms = [int]((Get-Date) - $start).TotalMilliseconds
    return [pscustomobject]@{ Status = $status; Instance = $instance; Ms = $ms; Body = $content }
}

# Перевірки на старті: гілка, свіжий код, Docker
function Start-AwsLab($branch) {
    Say "Підготовка: гілка $branch, Docker"
    $current = "$(git rev-parse --abbrev-ref HEAD)".Trim()
    if ($current -ne $branch) {
        Write-Host "Зараз гілка '$current'. Спершу виконайте: git checkout $branch" -ForegroundColor Red
        exit 1
    }
    Run 'git pull'
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Docker не запущений. Відкрийте Docker Desktop і дочекайтеся Engine running.' -ForegroundColor Red
        exit 1
    }
    $mk = "$(minikube status --format '{{.Host}}' 2>$null)".Trim()
    if ($mk -eq 'Running') {
        $ans = Read-Host 'Працює minikube (ЛР-3…7) і забирає пам''ять. Зупинити його на час цієї роботи? (y/n)'
        if ($ans -eq 'y') { Run 'minikube stop' }
    }
}

function Start-LocalStack {
    Run 'docker compose -f aws/docker-compose.yml up -d --build'
    WaitFor 'LocalStack готовий (перший раз завантажується образ ~1 ГБ)' { LocalStackHealthy } 900
}
