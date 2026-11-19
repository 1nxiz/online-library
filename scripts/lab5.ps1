# ЛР-5. GitOps з Argo CD — покроковий скрипт зі зупинками для скріншотів.
# Запуск з кореня репозиторію (гілка lab5):
#   powershell -ExecutionPolicy Bypass -File scripts\lab5.ps1
. "$PSScriptRoot\common.ps1"
Start-Lab 'lab5'

# --- залишки ЛР-3/ЛР-4 заважають: Argo CD має створити застосунок сам ---
$hasApp = kubectl get application online-library -n argocd 2>$null
$hasNs = kubectl get namespace online-library 2>$null
if ((-not $hasApp) -and $hasNs) {
    $ans = Read-Host "Namespace online-library залишився з ЛР-3/4. Видалити його? (y/n)"
    if ($ans -eq 'y') { Run 'kubectl delete namespace online-library --wait=true' }
}

Say '1. Репозиторій конфігурації (п.1) і образ у реєстрі (п.2)'
Run 'code argocd-apps/online-library.yaml'
Shot '5.1' 'VS Code: зліва папки bootstrap, argocd-apps, charts; відкритий argocd-apps/online-library.yaml'
Start-Process 'https://github.com/1nxiz/online-library/pkgs/container/online-library-backend/versions'
Shot '5.2' 'браузер: GHCR, пакет online-library-backend з тегами 1.0.0, 1.1.0'

Say '2. Встановлення Argo CD (п.3)'
kubectl get deployment argocd-server -n argocd *> $null
if ($LASTEXITCODE -ne 0) {
    Run 'kubectl create namespace argocd'
    Run 'kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml'
}
WaitFor 'усі поди Argo CD Running (перший раз до 10 хв)' {
    $notReady = kubectl get pods -n argocd --no-headers 2>$null | Where-Object { $_ -notmatch '\s1/1\s+Running' -and $_ -notmatch 'Completed' }
    ($notReady.Count -eq 0) -and (kubectl get pods -n argocd --no-headers 2>$null)
} 900
Run 'kubectl get pods -n argocd'
Shot '5.3' 'термінал: kubectl get pods -n argocd — усі Running'

Say '3. Вхід в Argo CD і зміна пароля admin (п.3)'
Show "kubectl -n argocd get secret argocd-initial-admin-secret -o go-template='{{.data.password | base64decode}}'"
$pass = kubectl -n argocd get secret argocd-initial-admin-secret -o 'go-template={{.data.password | base64decode}}' 2>$null
Write-Host "  Початковий пароль admin: $pass" -ForegroundColor White
Ensure-PortForward 'argocd-server' 'argocd' '8443:443' 8443
Start-Process 'https://localhost:8443'
Ask "У браузері: «Додатково» -> «Перейти на сайт», логін admin, пароль $pass. Потім ліворуч User Info -> Update Password -> новий пароль (запишіть його!)"
Shot '5.4' 'браузер: сторінка User Info після зміни пароля (або вхід з новим паролем)'

Say '4. Застосунок через App of Apps (п.4)'
kubectl get namespace online-library *> $null
if ($LASTEXITCODE -ne 0) { Run 'kubectl create namespace online-library' }
kubectl get secret library-db-secret -n online-library *> $null
if ($LASTEXITCODE -ne 0) { Run 'kubectl create secret generic library-db-secret -n online-library --from-literal=DB_PASSWORD=LibraryPass123' }
Run 'kubectl apply -f bootstrap/root-app.yaml'
WaitFor 'online-library: Synced / Healthy' { (AppStatus 'online-library') -eq 'Synced/Healthy' } 900
Run 'kubectl get applications -n argocd'
Shot '5.5' 'термінал: kubectl apply -f bootstrap/root-app.yaml і kubectl get applications -n argocd'
Ask 'У браузері Argo CD клацніть картку online-library (видно дерево обʼєктів)'
Shot '5.6' 'браузер: дерево online-library, зверху Synced і Healthy'

Say '5. Реліз через Git (п.5): тег 1.0.0 -> 1.1.0'
EditFile $Values 's/^(    tag: .)[0-9.]+(.*)$/\11.1.0\2/'
Run "code $Values"
Run 'git --no-pager diff'
CommitPush 'release 1.1.0'
Shot '5.7' 'VS Code з файлом values-minikube.yaml + термінал з git diff, commit і push'
Refresh 'online-library'
WaitFor 'новий образ 1.1.0 розгорнуто' {
    $img = kubectl get deployment online-library-backend -n online-library -o 'jsonpath={.spec.template.spec.containers[0].image}' 2>$null
    ("$img" -match ':1\.1\.0$') -and ((AppStatus 'online-library') -eq 'Synced/Healthy')
} 600
kubectl delete pod ver -n online-library --ignore-not-found *> $null
Run 'kubectl run ver --rm -i --restart=Never -n online-library --image=curlimages/curl -- curl -s http://online-library-backend:5000/version'
Open-Window 'minikube service online-library-frontend -n online-library'
Ask 'Відкриється сторінка бібліотеки з бейджем v1.1.0. В Argo CD (online-library) натисніть Refresh — видно новий коміт у полі LAST SYNC'
Shot '5.8' 'браузер: Argo CD з новим комітом + сторінка з бейджем v1.1.0'

Say '6. Дрейф без selfHeal (п.6a): OutOfSync'
EditFile 'argocd-apps/online-library.yaml' 's/selfHeal: true/selfHeal: false/'
CommitPush 'selfHeal off'
Refresh 'root'
WaitFor 'Argo CD прийняв selfHeal: false' {
    "$(kubectl get application online-library -n argocd -o 'jsonpath={.spec.syncPolicy.automated.selfHeal}' 2>$null)" -ne 'true'
} 300
Run 'kubectl scale deployment online-library-backend -n online-library --replicas=5'
WaitFor 'online-library став OutOfSync' { (AppStatus 'online-library') -like 'OutOfSync*' } 300
Run 'kubectl get applications -n argocd'
Ask 'У браузері відкрийте online-library -> кнопка APP DIFF (видно replicas 2 у Git проти 5 у кластері)'
Shot '5.9' 'браузер: online-library OutOfSync (жовтий) + вікно App Diff'

Say '7. selfHeal: true — Argo CD повертає значення з Git (п.6a)'
EditFile 'argocd-apps/online-library.yaml' 's/selfHeal: false/selfHeal: true/'
CommitPush 'selfHeal on'
Refresh 'root'
WaitFor 'кількість реплік повернулась до 2' {
    "$(kubectl get deployment online-library-backend -n online-library -o 'jsonpath={.spec.replicas}' 2>$null)" -eq '2'
} 300
Run 'kubectl get deployment online-library-backend -n online-library'
Shot '5.10' 'термінал: READY 2/2 після selfHeal (вище видно kubectl scale --replicas=5)'

Say '8. Неіснуючий тег: Synced, але Degraded (п.6b)'
EditFile $Values 's/^(    tag: .)[0-9.]+(. # <-.*)$/\19.9.9\2/'
Run 'git --no-pager diff'
CommitPush 'release 9.9.9 (неіснуючий тег)'
Refresh 'online-library'
WaitFor 'online-library: Synced / Degraded (близько 2 хв)' { (AppStatus 'online-library') -eq 'Synced/Degraded' } 600
Run 'kubectl get pods -n online-library'
Shot '5.11' 'браузер: online-library Synced + червоний Degraded, поруч термінал з подом ImagePullBackOff'

Say '9. Відкат через git revert (п.6c)'
Run 'git revert --no-edit HEAD'
Run 'git push'
Refresh 'online-library'
WaitFor 'online-library знову Synced / Healthy' { (AppStatus 'online-library') -eq 'Synced/Healthy' } 600
Run 'git --no-pager log --oneline -6'
Ask 'У браузері: online-library -> кнопка HISTORY AND ROLLBACK (список ревізій з комітами)'
Shot '5.12' 'термінал з git log + браузер History and Rollback'
Shot '5.13' 'браузер: online-library знову Synced / Healthy'

Say 'ЛР-5 завершено. Наступна: git checkout lab6; git pull; powershell -ExecutionPolicy Bypass -File scripts\lab6.ps1'
