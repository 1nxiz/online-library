# Лабораторна робота №6. Progressive delivery: canary з Argo Rollouts

**Мета:** замінити звичайне оновлення Deployment поступовим релізом, який можна зупинити на проміжному кроці, перевірити і скасувати.

**Обрана стратегія:** **canary**.

## 1. Що зроблено в коді

| Файл | Пояснення |
|---|---|
| `argocd-apps/argo-rollouts.yaml` | Application для офіційного Helm-чарта `argo-rollouts` 2.43.8 (контролер v1.10.1) з `https://argoproj.github.io/argo-helm`. Root-застосунок підхоплює його з Git, як і бібліотеку. `sync-wave: "-1"` і `ServerSideApply=true` для CRD |
| `charts/online-library/templates/backend-rollout.yaml` | шаблон `Rollout`. Вмикається параметром `rollout.enabled: true` і **замінює** `backend-deployment.yaml`, який має умову `if not .Values.rollout.enabled` |
| `charts/online-library/templates/_helpers.tpl` | `library.backendPod` — спільний шаблон пода для Deployment і Rollout, тож код не дублюється |
| `charts/online-library/values.yaml` | `rollout.replicaCount: 4` і кроки canary |
| `charts/online-library/values-minikube.yaml` | `rollout.enabled` (у ЛР-5 `false`, у ЛР-6 `true`) |
| `argocd-apps/online-library.yaml` | `SkipDryRunOnMissingResource=true` (CRD Rollout може з'явитися пізніше) і `sync-wave: "1"` |

Кроки canary в `values.yaml`:

```yaml
rollout:
  enabled: false
  replicaCount: 4
  canary:
    steps:
      - setWeight: 25          # 1 под нової версії з 4
      - pause: {}              # РУЧНА пауза: чекає promote
      - setWeight: 50          # 2 з 4
      - pause: { duration: 30s }   # пауза з таймером
      - setWeight: 75          # 3 з 4
      - pause: { duration: 30s }
```

Без traffic manager (Istio, Nginx) Argo Rollouts досягає ваги **кількістю подів**. Тому реплік 4: 25% = рівно 1 канарковий под, і співвідношення версій видно наочно. Service `online-library-backend` вибирає поди обох версій, тож запити розподіляються пропорційно.

### Чому саме canary для «Онлайн бібліотеки»

1. **Backend без стану**, а всі репліки працюють з однією БД. Дві версії можуть працювати одночасно, і canary цим користується.
2. **Обмежений ризик:** нову версію спершу отримує лише ~25% запитів. Якщо вона зламана (не працює пошук чи видача книги), постраждає частина читачів, а реліз можна перервати `abort`.
3. **Економія ресурсів:** blue-green тримає дві повні копії (4 + 4 поди), а canary додає по одному поду. Для minikube на ноутбуці це важливо.
4. **Не потрібні додаткові Service:** blue-green вимагає `activeService` і `previewService`, а canary працює з наявним Service чарта.

Blue-green кращий, коли дві версії **не можна** запускати разом (несумісна схема БД) або потрібне миттєве перемикання. Для нашого застосунку це не так.

## 2. Хід виконання (PowerShell)

Стартовий стан після ЛР-5: Argo CD працює, `online-library` Synced/Healthy з тегом `1.1.0`. У гілці `lab6` в `values-minikube.yaml` теж тег `1.1.0`.

### 2.1. Контролер через Argo CD (п.1a)

Усі коміти ЛР-6 робляться в гілці `lab6`. Перемкніть root з `lab5` на `lab6` — це єдиний ручний крок:

```powershell
git checkout lab6
kubectl apply -f bootstrap/root-app.yaml      # targetRevision: lab6
argocd app get root --refresh
argocd app get argo-rollouts                  # з'явився новий Application: Synced / Healthy
kubectl get pods -n argo-rollouts
kubectl get crd | Select-String rollouts
```

Root знайшов у `argocd-apps/` новий файл `argo-rollouts.yaml` і встановив контролер з офіційного Helm-чарта (sync-wave `-1`, тобто раніше за застосунок).

### 2.2. Плагін kubectl argo rollouts (п.1b)

```powershell
mkdir C:\tools -Force
Invoke-WebRequest -Uri https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/kubectl-argo-rollouts-windows-amd64 -OutFile C:\tools\kubectl-argo-rollouts.exe
$env:Path += ";C:\tools"     # постійно: Параметри системи → Змінні середовища → Path
kubectl argo rollouts version
```

### 2.3. Rollout замість Deployment (п.2)

У гілці `lab6` у `charts/online-library/values-minikube.yaml` уже стоїть `rollout.enabled: true`, тому після перемикання root Argo CD сам видалив Deployment backend і створив Rollout:

```powershell
argocd app get online-library --refresh
kubectl get rollout,deploy -n online-library    # Deployment backend зник, з'явився Rollout
kubectl argo rollouts get rollout online-library-backend -n online-library
```

Перше створення Rollout відбувається без кроків, одразу 4 поди: canary діє лише при *зміні* версії.

### 2.4. Реліз комітом і promote (п.4a)

Відкрийте три термінали.

**Термінал 1 — стан Rollout:**

```powershell
kubectl argo rollouts get rollout online-library-backend -n online-library --watch
```

**Термінал 2 — цикл запитів усередині кластера:**

```powershell
kubectl run loop --rm -it --restart=Never -n online-library --image=curlimages/curl -- sh -c 'while true; do curl -s http://online-library-backend:5000/version; echo; sleep 0.5; done'
```

**Термінал 3 — реліз:** у `values-minikube.yaml` поставте `backend.image.tag: "1.2.0"`, потім:

```powershell
git commit -am "release 1.2.0 (canary)"
git push
argocd app get online-library --refresh
```

Що видно:

- **Термінал 1:** `Step: 1/6`, `SetWeight: 25`, `Status: ॥ Paused (CanaryPauseStep)`. Ревізія 2 (canary) має 1 под, ревізія 1 (stable) — 3 поди.
- **Термінал 2:** приблизно кожна четверта відповідь `{"version":"1.2.0"}`, решта `{"version":"1.1.0"}`.
- **Argo CD UI:** застосунок **Synced**, Health **Suspended** (Rollout на паузі). У дереві Rollout → два ReplicaSet.
- **Дашборд (опційно):** `kubectl argo rollouts dashboard` → http://localhost:3100 показує кроки і кнопку *Promote*.

Promote на ручній паузі:

```powershell
kubectl argo rollouts promote online-library-backend -n online-library
```

Далі автоматично: 50% (2/4) → пауза 30 с → 75% (3/4) → пауза 30 с → 100%. У терміналі 2 частка `1.2.0` зростає до 100%, у терміналі 1 `Status: ✔ Healthy`, в Argo CD **Synced / Healthy**.

### 2.5. Abort і відкат через Git (п.5)

Новий реліз: `backend.image.tag: "1.3.0"`, потім:

```powershell
git commit -am "release 1.3.0 (canary, буде скасовано)"
git push
argocd app get online-library --refresh
# дочекатися паузи на 25% (1 под 1.3.0), потім:
kubectl argo rollouts abort online-library-backend -n online-library
kubectl argo rollouts get rollout online-library-backend -n online-library
argocd app get online-library
```

Після `abort` canary-под видаляється, усі 4 поди знову stable `1.2.0` (цикл запитів відповідає лише `1.2.0`). Rollout отримує статус `✖ Degraded` (*RolloutAborted*).

**Чому Argo CD показує Synced / Degraded:**

- **Synced:** Argo CD порівнює *маніфести*. У Git тег `1.3.0` і в специфікації Rollout у кластері теж `1.3.0`, тож розбіжностей немає. `abort` не змінює spec, лише стан виконання.
- **Degraded:** health Rollout береться зі статусу. Реліз перервано, бажана версія `1.3.0` не розгорнута, і кластер навмисно працює на старій версії. Це сигнал, що Git описує стан, якого кластер не досяг.

Тобто Git і кластер «згодні» щодо конфігурації, але реліз не відбувся. Щоб стани знову збіглися, треба привести Git до фактичної версії:

```powershell
git revert --no-edit HEAD
git push
argocd app get online-library --refresh
kubectl argo rollouts get rollout online-library-backend -n online-library   # ✔ Healthy, 1.2.0
git log --oneline -5
argocd app history online-library
```

Spec знову вказує `1.2.0` (stable ReplicaSet), тому Rollout стає Healthy без перезапуску подів, а застосунок **Synced / Healthy**.

### 2.6. Шпаргалка для захисту (п.6)

1. Термінали 1 і 2 з п.2.4 відкриті, Argo CD UI відкритий.
2. Реліз комітом: тег → commit → push → Refresh.
3. Проміжний стан: 1 з 4 подів нові, змішані відповіді, *Paused* / *Suspended*.
4. `promote`, щоб довести реліз до 100%.
5. Ще один реліз, на паузі `abort`, показати **Synced / Degraded** і пояснити (див. вище).
6. `git revert` → push, після чого Synced / Healthy.

## 3. Скріншоти для звіту

| № | Файл | Що на скріншоті |
|---|---|---|
| 1 | `lab6-01-rollouts-app.png` | `argocd-apps/argo-rollouts.yaml` у VS Code і застосунок `argo-rollouts` Healthy в Argo CD |
| 2 | `lab6-02-controller-crd.png` | `kubectl get pods -n argo-rollouts` і CRD `rollouts.argoproj.io` |
| 3 | `lab6-03-plugin.png` | `kubectl argo rollouts version` |
| 4 | `lab6-04-rollout-template.png` | `backend-rollout.yaml` і кроки canary у `values.yaml` |
| 5 | `lab6-05-rollout-created.png` | `kubectl get rollout,deploy` після `rollout.enabled: true` |
| 6 | `lab6-06-release-commit.png` | commit/push з тегом 1.2.0 |
| 7 | `lab6-07-paused-25.png` | `get rollout --watch`: Paused, 1 canary + 3 stable |
| 8 | `lab6-08-mixed-responses.png` | цикл запитів зі змішаними 1.1.0 / 1.2.0 |
| 9 | `lab6-09-argocd-suspended.png` | Argo CD: Synced / Suspended, два ReplicaSet у дереві |
| 10 | `lab6-10-promote.png` | `promote` і перехід 50% → 75% → 100% |
| 11 | `lab6-11-healthy-120.png` | Rollout Healthy, усі відповіді 1.2.0 |
| 12 | `lab6-12-abort.png` | `abort` на 25% і статус Degraded (RolloutAborted) |
| 13 | `lab6-13-synced-degraded.png` | Argo CD: **Synced / Degraded** |
| 14 | `lab6-14-revert.png` | `git revert`, `git log`, `argocd app history` |
| 15 | `lab6-15-final-healthy.png` | Argo CD: Synced / Healthy, Rollout на 1.2.0 |
| 16 | `lab6-16-dashboard.png` (опційно) | дашборд Argo Rollouts |

## 4. Висновок

Backend переведено з Deployment на Argo Rollout зі стратегією canary: 4 репліки, кроки 25/50/75%, ручна пауза і паузи з таймером. Контролер Argo Rollouts, як і застосунок, встановлюється з Git через Argo CD. Реліз виконується комітом і проходить поступово: його можна перевірити на частині трафіку, підтвердити `promote` або скасувати `abort` з миттєвим поверненням на стабільну версію. Остаточний відкат виконується через `git revert`.
