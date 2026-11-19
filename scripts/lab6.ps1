# ЛР-6. Canary з Argo Rollouts — покроковий скрипт зі зупинками для скріншотів.
# Запуск з кореня репозиторію (гілка lab6):
#   powershell -ExecutionPolicy Bypass -File scripts\lab6.ps1
# Замість kubectl-argo-rollouts.exe використовується той самий інструмент у Docker (функція rollouts).
. "$PSScriptRoot\common.ps1"
Start-Lab 'lab6'
Ensure-PortForward 'argocd-server' 'argocd' '8443:443' 8443

Say '1. Rollout у Helm-чарті і стратегія canary (п.2–3)'
Run 'code charts/online-library/templates/backend-rollout.yaml charts/online-library/values.yaml'
Ask 'У VS Code: правий клік на вкладці values.yaml -> Split Right; у values.yaml прокрутіть до блоку rollout:'
Shot '6.1' 'VS Code: backend-rollout.yaml і блок rollout: у values.yaml (кроки setWeight / pause)'

Say '2. Контролер Argo Rollouts з Git (п.1a) і плагін (п.1b)'
Run 'kubectl apply -f bootstrap/root-app.yaml'
Refresh 'root'
WaitFor 'argo-rollouts: Synced / Healthy' { (AppStatus 'argo-rollouts') -eq 'Synced/Healthy' } 900
Run 'kubectl get applications -n argocd'
Run 'kubectl get pods -n argo-rollouts'
Run 'kubectl get crd | Select-String rollouts'
Start-Process 'https://localhost:8443/applications/argocd/argo-rollouts'
Shot '6.2' 'термінал (поди argo-rollouts, CRD) + браузер: застосунок argo-rollouts Synced / Healthy'
Show 'kubectl argo rollouts version   (у Docker)'
rollouts version
Shot '6.3' 'термінал: версія kubectl argo rollouts'
Refresh 'online-library'
WaitFor 'Rollout створено і він Healthy' { (RolloutPhase) -eq 'Healthy' } 900
Run 'kubectl get rollout,deploy -n online-library'
Shot '6.4' 'термінал: є rollout online-library-backend (4 репліки), Deployment backend немає'

Say '3. Реліз через Git і проміжний стан (п.4a): тег -> 1.2.0'
Open-WatchWindow
Open-LoopWindow
Ask 'Відкрились два вікна: (1) стан Rollout, (2) цикл запитів /version. Розташуйте їх поруч'
EditFile $Values 's/^(    tag: .)[0-9.]+(. # <-.*)$/\11.2.0\2/'
Run 'git --no-pager diff'
CommitPush 'release 1.2.0 (canary)'
Refresh 'online-library'
WaitFor 'Rollout на ручній паузі (25%)' { (RolloutPhase) -eq 'Paused' } 600
Start-Sleep -Seconds 10
Shot '6.5' 'вікно стану Rollout: Status Paused, Step 1/6, SetWeight 25, 1 под нової ревізії і 3 старої'
Shot '6.6' 'вікно циклу запитів: змішані {"version":"1.1.0"} і {"version":"1.2.0"}'
Start-Process 'https://localhost:8443/applications/argocd/online-library'
Shot '6.7' 'браузер Argo CD: online-library Synced + Suspended, у дереві Rollout і два ReplicaSet'

Say '4. Promote на ручній паузі (п.4a)'
Show 'kubectl argo rollouts promote online-library-backend -n online-library   (у Docker)'
rollouts promote online-library-backend -n online-library
Start-Sleep -Seconds 15
Shot '6.8' 'термінал з promote + вікно стану Rollout на кроці SetWeight 50 або 75'
WaitFor 'реліз дійшов до 100% (Healthy)' { (RolloutPhase) -eq 'Healthy' } 300
Start-Sleep -Seconds 5
Shot '6.9' 'вікно стану: Healthy, 4 поди 1.2.0; вікно циклу: тільки {"version":"1.2.0"}'

Say '5. Ще один реліз і abort (п.5): тег -> 1.3.0'
EditFile $Values 's/^(    tag: .)[0-9.]+(. # <-.*)$/\11.3.0\2/'
CommitPush 'release 1.3.0 (canary, буде скасовано)'
Refresh 'online-library'
WaitFor 'Rollout на паузі 25% з версією 1.3.0' { (RolloutPhase) -eq 'Paused' } 600
Show 'kubectl argo rollouts abort online-library-backend -n online-library   (у Docker)'
rollouts abort online-library-backend -n online-library
WaitFor 'Rollout Degraded (повернувся на stable)' { (RolloutPhase) -eq 'Degraded' } 300
Show 'kubectl argo rollouts get rollout online-library-backend -n online-library   (у Docker)'
rollouts get rollout online-library-backend -n online-library
Shot '6.10' 'термінал/вікно стану: Status Degraded (RolloutAborted), усі 4 поди stable 1.2.0; цикл відповідає лише 1.2.0'
Refresh 'online-library'
WaitFor 'Argo CD показує Synced / Degraded' { (AppStatus 'online-library') -eq 'Synced/Degraded' } 300
Shot '6.11' 'браузер Argo CD: online-library Synced (зелений) + Degraded (червоний)'

Say '6. Завершення відкату через Git (п.5)'
Run 'git revert --no-edit HEAD'
Run 'git push'
Refresh 'online-library'
WaitFor 'Rollout Healthy і Argo CD Synced / Healthy' { ((RolloutPhase) -eq 'Healthy') -and ((AppStatus 'online-library') -eq 'Synced/Healthy') } 600
Run 'git --no-pager log --oneline -5'
Show 'kubectl argo rollouts get rollout online-library-backend -n online-library   (у Docker)'
rollouts get rollout online-library-backend -n online-library
Shot '6.12' 'термінал: git revert, git log і стан Rollout Healthy на 1.2.0'
Shot '6.13' 'браузер Argo CD: online-library Synced / Healthy'

Write-Host ''
Write-Host 'Вікна стану і циклу запитів можна закрити (Ctrl+C, потім закрити вікно).' -ForegroundColor Gray
Say 'ЛР-6 завершено. Наступна: git checkout lab7; git pull; powershell -ExecutionPolicy Bypass -File scripts\lab7.ps1'
