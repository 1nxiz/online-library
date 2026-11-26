# Спільні функції для скриптів scripts\labN.ps1 (ЛР-5, ЛР-6, ЛР-7).
# Працює у Windows PowerShell 5.1, без argocd.exe і kubectl-argo-rollouts.exe:
# Argo Rollouts запускається в Docker, правки YAML — через sed у Docker (UTF-8 без зіпсованих коментарів).

$ErrorActionPreference = 'Continue'
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $Repo

$RolloutsImage = 'quay.io/argoproj/kubectl-argo-rollouts:v1.10.1'
$Values = 'charts/online-library/values-minikube.yaml'

function Say($text) {
    Write-Host ''
    Write-Host "==================== $text" -ForegroundColor Cyan
}

function Show($cmd) {
    Write-Host "PS> $cmd" -ForegroundColor Yellow
}

# Виконати команду і показати її в терміналі (щоб на скріншоті було видно і команду, і результат)
function Run($cmd) {
    Show $cmd
    Invoke-Expression $cmd
}

function Shot($num, $what) {
    Write-Host ''
    Write-Host "  >>> СКРІН $num : $what" -ForegroundColor Green
    Read-Host '  Зробіть скріншот (Win+Shift+S), вставте у звіт і натисніть Enter' | Out-Null
}

function Ask($text) {
    Write-Host ''
    Write-Host "  >>> $text" -ForegroundColor Magenta
    Read-Host '  Коли зробите — натисніть Enter' | Out-Null
}

# Чекати, поки $check поверне $true (перевірка кожні 5 с)
function WaitFor($desc, [scriptblock]$check, $timeoutSec = 600) {
    Write-Host "  ... чекаю: $desc " -NoNewline
    $start = Get-Date
    while (-not (& $check)) {
        if (((Get-Date) - $start).TotalSeconds -gt $timeoutSec) {
            Write-Host ''
            Write-Host "  Не дочекався за $timeoutSec с." -ForegroundColor Red
            Read-Host '  Перевірте стан (див. вище) і натисніть Enter, щоб продовжити, або Ctrl+C, щоб зупинити' | Out-Null
            return
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 5
    }
    Write-Host ' готово' -ForegroundColor Green
}

function AppStatus($name) {
    $s = kubectl get application $name -n argocd -o 'jsonpath={.status.sync.status}/{.status.health.status}' 2>$null
    return "$s"
}

# Попросити Argo CD негайно перечитати Git (замість кнопки Refresh / argocd app get --refresh)
function Refresh($name) {
    kubectl -n argocd annotate application $name argocd.argoproj.io/refresh=hard --overwrite *> $null
}

function RolloutPhase {
    $p = kubectl get rollout online-library-backend -n online-library -o 'jsonpath={.status.phase}' 2>$null
    return "$p"
}

# Правка файлу sed-виразом усередині Docker (зберігає UTF-8 і LF)
function EditFile($file, $expr) {
    docker run --rm -v "${Repo}:/w" -w /w debian:bookworm-slim sed -i -E $expr $file
}

function CommitPush($msg) {
    Show "git commit -am `"$msg`""
    git commit -am $msg
    Show 'git push'
    git push
}

# kubeconfig для контейнерів у мережі minikube (адреса API-сервера 192.168.49.2:8443)
function Update-DockerKubeconfig {
    $ip = "$(minikube ip)".Trim()
    $cfg = kubectl config view --flatten --minify --context minikube
    ($cfg -replace 'https://127\.0\.0\.1:\d+', "https://${ip}:8443") | Set-Content -Encoding ascii "$Repo\kubeconfig-docker.yaml"
    if (-not (Select-String -Path "$Repo\.git\info\exclude" -Pattern 'kubeconfig-docker' -Quiet)) {
        Add-Content "$Repo\.git\info\exclude" 'kubeconfig-docker.yaml'
    }
}

# Замінник «kubectl argo rollouts ...»
function rollouts {
    docker run --rm -i --network minikube -v "$Repo\kubeconfig-docker.yaml:/kubeconfig" $RolloutsImage --kubeconfig /kubeconfig @args
}

# Замінник «helm ...» (для ЛР-4)
function helm {
    docker run --rm -i --network minikube -v "${Repo}:/apps" -w /apps -v "$Repo\kubeconfig-docker.yaml:/root/.kube/config" alpine/helm:3.19.0 @args
}

# Відкрити окреме вікно PowerShell з довгою командою (watch, цикл запитів, port-forward)
function Open-Window($command) {
    Show "(нове вікно) $command"
    Start-Process powershell -ArgumentList ('-NoExit -Command "' + $command + '"')
}

function Open-WatchWindow {
    $cmd = "docker run --rm -it --network minikube -v '$Repo\kubeconfig-docker.yaml:/kubeconfig' $RolloutsImage --kubeconfig /kubeconfig get rollout online-library-backend -n online-library --watch"
    Open-Window $cmd
}

function Open-LoopWindow {
    kubectl delete pod loop -n online-library --ignore-not-found *> $null
    Open-Window "kubectl run loop --rm -it --restart=Never -n online-library --image=curlimages/curl -- sh -c 'while true; do curl -s http://online-library-backend:5000/version; echo; sleep 0.5; done'"
}

function PortListening($port) {
    return [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function Ensure-PortForward($svc, $ns, $ports, $localPort) {
    if (-not (PortListening $localPort)) {
        Open-Window "kubectl port-forward svc/$svc -n $ns $ports"
        WaitFor "port-forward на порт $localPort" { PortListening $localPort } 60
    }
}

# Перевірки на старті: потрібна гілка, свіжий код, запущений minikube
function Start-Lab($branch) {
    Say "Підготовка: гілка $branch, minikube"
    $current = "$(git rev-parse --abbrev-ref HEAD)".Trim()
    if ($current -ne $branch) {
        Write-Host "Зараз гілка '$current'. Спершу виконайте: git checkout $branch" -ForegroundColor Red
        exit 1
    }
    Run 'git pull'
    $host_state = "$(minikube status --format '{{.Host}}' 2>$null)".Trim()
    if ($host_state -ne 'Running') {
        Run 'minikube start --driver=docker --cpus 4 --memory 7000'
    }
    Update-DockerKubeconfig
    Run 'kubectl get nodes'
}
