# Лабораторна робота №5. GitOps: розгортання через Argo CD

**Мета:** замість ручного `helm upgrade --install` описати бажаний стан кластера в Git, щоб Argo CD сам приводив кластер до нього.

## 1. Що зроблено в коді

Обрано **варіант b**: каталоги `bootstrap/`, `argocd-apps/`, `charts/` у репозиторії застосунку.

| Файл | Пояснення |
|---|---|
| `bootstrap/root-app.yaml` | кореневий Application `root` (App of Apps). **Лише його** застосовують вручну. Він дивиться на каталог `argocd-apps/` |
| `argocd-apps/online-library.yaml` | Application чарта `charts/online-library` з `values-minikube.yaml`. Має `automated` (prune + selfHeal), `CreateNamespace=true` і retry |
| `charts/online-library/` | Helm-чарт з ЛР-4 |
| `charts/online-library/values-minikube.yaml` | значення для minikube. Тут змінюється тег образу для релізу |
| `backend/app.py` | ендпоінти `/version` і `/api/version`, поле `version` у `/health`, бейдж версії на сторінці |

**Без паролів у Git:** у `values-minikube.yaml` вказано `secret.existingSecret: library-db-secret`. Сам Secret створюється в кластері однією командою `kubectl`, і в репозиторії його значення немає.

**Образ у реєстрі:** CI з ЛР-2 публікує `ghcr.io/<логін>/online-library-backend:<версія>` при push git-тега. Пакет публічний, тож кластер завантажує його сам, без `minikube image load`.

**Швидкий Degraded:** у Deployment backend задано `progressDeadlineSeconds: 90`. Тому при неіснуючому тезі Argo CD покаже *Degraded* приблизно через 1,5 хвилини, а не через стандартні 10.

> Файл `argocd-apps/argo-rollouts.yaml` і параметр `rollout.enabled` належать ЛР-6. У ЛР-5 `rollout.enabled: false`, тож backend — звичайний Deployment. Якщо хочете чисту історію комітів по лабораторних, додайте `argo-rollouts.yaml` окремим комітом на початку ЛР-6. Якщо файл уже є, він лише встановить контролер і не завадить.

## 2. Хід виконання (PowerShell)

### 2.1. Підготовка

- Образи `1.0.0`, `1.1.0`, `1.2.0`, `1.3.0` опубліковані (ЛР-2) і пакети **Public**.
- Реліз з ЛР-4 видалено (`helm uninstall library -n online-library`).
- У `argocd-apps/*.yaml` і `bootstrap/root-app.yaml` `repoURL` вказує на ваш репозиторій (заміна `1nxiz`).
- `values-minikube.yaml`: `backend.image.tag: "1.0.0"`, `rollout.enabled: false`. Закомітьте і запуште.

### 2.2. Встановлення Argo CD (п.3)

```powershell
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w        # усі Running, Ctrl+C
```

CLI для Windows: завантажте `argocd-windows-amd64.exe` з https://github.com/argoproj/argo-cd/releases/latest, перейменуйте на `argocd.exe` і покладіть у теку з `PATH`.

```powershell
argocd version --client
# окремий термінал (тримати відкритим):
kubectl port-forward svc/argocd-server -n argocd 8443:443
# основний термінал:
argocd admin initial-password -n argocd
argocd login localhost:8443 --username admin --insecure
argocd account update-password
```

Веб-інтерфейс: https://localhost:8443 (сертифікат самопідписаний, прийміть попередження). Увійдіть як `admin` з новим паролем.

Якщо репозиторій **приватний**:

```powershell
argocd repo add https://github.com/<логін>/online-library.git --username <логін> --password <GitHub PAT з правом read>
```

### 2.3. App of Apps (п.4)

```powershell
kubectl create namespace online-library
kubectl create secret generic library-db-secret -n online-library --from-literal=DB_PASSWORD=<придумайте-пароль>
kubectl apply -f bootstrap/root-app.yaml        # ЄДИНИЙ ручний apply
argocd app list
argocd app get online-library
kubectl get all -n online-library
minikube service online-library-frontend -n online-library
```

В інтерфейсі Argo CD відкрийте `root`: у дереві видно дочірні Application. Відкрийте `online-library`: дерево Deployment → ReplicaSet → Pod, Service, PVC, ConfigMap у стані **Synced / Healthy**. На сторінці застосунку бейдж показує `v1.0.0`.

### 2.4. Реліз комітом (п.5)

Змініть у `charts/online-library/values-minikube.yaml` значення `backend.image.tag: "1.1.0"` (і `frontend.image.tag: "1.1.0"`), потім:

```powershell
git commit -am "release 1.1.0"
git push
argocd app get online-library --refresh       # або зачекати до 3 хв автоматичного опитування
kubectl rollout status deployment/online-library-backend -n online-library
kubectl run ver --rm -it --restart=Never -n online-library --image=curlimages/curl -- curl -s http://online-library-backend:5000/version
```

У браузері (F5) бейдж змінюється на `v1.1.0`, а в Argo CD у *History* з'являється новий commit.

### 2.5. Дрейф і selfHeal (п.6a)

1. В `argocd-apps/online-library.yaml` поставте `selfHeal: false`, закомітьте і запуште. Дочекайтесь синхронізації `root`.
2. Змініть кластер вручну:

```powershell
kubectl scale deployment online-library-backend -n online-library --replicas=5
argocd app get online-library      # Sync Status: OutOfSync
argocd app diff online-library     # replicas: 2 (Git) vs 5 (кластер)
```

В інтерфейсі застосунок жовтий **OutOfSync**. На вкладці *Diff* видно `replicas`.

3. Поверніть `selfHeal: true`, закомітьте і запуште. Argo CD сам поверне 2 репліки:

```powershell
kubectl get deployment online-library-backend -n online-library -w
kubectl scale deployment online-library-backend -n online-library --replicas=5   # повторна спроба: за кілька секунд знову 2
```

### 2.6. Synced, але Degraded (п.6b)

```powershell
# у values-minikube.yaml: backend.image.tag: "9.9.9"
git commit -am "release 9.9.9 (неіснуючий тег)"
git push
argocd app get online-library --refresh
kubectl get pods -n online-library      # новий под ImagePullBackOff, старі працюють
```

Приблизно через 90 с: **Sync Status = Synced** (кластер відповідає Git), **Health = Degraded** (Deployment не може завершити оновлення). У дереві под позначено червоним, у його подіях видно `ErrImagePull`. Застосунок тим часом відповідає: старі поди не зупинялись (`maxUnavailable: 0`).

### 2.7. Відкат через git revert (п.6c)

```powershell
git revert --no-edit HEAD
git push
argocd app get online-library --refresh
git log --oneline -5
argocd app history online-library
```

Тег повертається до `1.1.0`, а застосунок знову **Synced / Healthy**. В `argocd app history` видно ревізії з відповідними commit SHA.

### 2.8. Шпаргалка для захисту (п.7)

| Викладач просить | Що робите |
|---|---|
| показати Argo CD | https://localhost:8443 → `root` → `online-library` (дерево) |
| реліз комітом | змінити `backend.image.tag` → commit → push → Refresh |
| змінити будь-яке значення | напр. `config.appTitle` або `backend.replicaCount` у `values-minikube.yaml` → commit → push. Заголовок сторінки або кількість подів змінюється |
| ручна зміна і selfHeal | `kubectl scale … --replicas=5` → за секунди знову 2 |
| Synced + Degraded | тег `9.9.9` → commit → push |
| відкат | `git revert HEAD` → push |

## 3. Скріншоти для звіту

| № | Файл | Що на скріншоті |
|---|---|---|
| 1 | `lab5-01-repo-structure.png` | дерево `bootstrap/`, `argocd-apps/`, `charts/` у VS Code |
| 2 | `lab5-02-ghcr-tags.png` | GHCR: образ з тегами 1.0.0 / 1.1.0 |
| 3 | `lab5-03-version-endpoint.png` | відповідь `/version` і бейдж версії на сторінці |
| 4 | `lab5-04-argocd-pods.png` | `kubectl get pods -n argocd` |
| 5 | `lab5-05-argocd-login.png` | вхід у UI після зміни пароля (`argocd account update-password`) |
| 6 | `lab5-06-root-app.png` | `kubectl apply -f bootstrap/root-app.yaml` і дерево `root` у UI |
| 7 | `lab5-07-app-tree-healthy.png` | дерево `online-library`: **Synced / Healthy** |
| 8 | `lab5-08-release-commit.png` | `git commit/push` зі зміною тега і diff у VS Code |
| 9 | `lab5-09-release-synced.png` | Argo CD з новим commit і бейдж `v1.1.0` у браузері |
| 10 | `lab5-10-outofsync.png` | після `kubectl scale`: **OutOfSync** і вкладка Diff |
| 11 | `lab5-11-selfheal.png` | після `selfHeal: true` репліки повернулись до 2 |
| 12 | `lab5-12-degraded.png` | **Synced + Degraded**, под з ImagePullBackOff |
| 13 | `lab5-13-revert-gitlog.png` | `git revert`, `git log --oneline` |
| 14 | `lab5-14-app-history.png` | `argocd app history online-library` і Healthy після відкату |

## 4. Висновок

Розгортання переведено на GitOps: бажаний стан описано в Git, а Argo CD через App of Apps сам встановлює і оновлює застосунок. Реліз робиться комітом зі зміною тега. Ручні зміни в кластері виявляються як OutOfSync і з `selfHeal` повертаються автоматично. Невдалий реліз видно як Synced + Degraded, а відкат виконується звичайним `git revert`.
