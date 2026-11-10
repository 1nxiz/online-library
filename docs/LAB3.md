# Лабораторна робота №3. Розгортання застосунку в Kubernetes

**Мета:** описати «Онлайн бібліотеку» маніфестами Kubernetes, розгорнути в minikube і показати керування життєвим циклом через `kubectl`.

## 1. Що зроблено в коді

Каталог `k8s/` містить по одному файлу на кожен об'єкт. Namespace `online-library` збігається з назвою проєкту.

| Файл | Об'єкт | Пояснення |
|---|---|---|
| `00-namespace.yaml` | Namespace | префікс `00-`, щоб namespace створювався першим при `kubectl apply -f k8s/` |
| `configmap.yaml` | ConfigMap `library-config` | параметри застосунку і БД |
| `secret.yaml` | Secret `library-secret` | пароль БД (навчальний) |
| `postgres-pvc.yaml` | PersistentVolumeClaim | 1Gi для даних PostgreSQL (компонент зі станом) |
| `postgres-deployment.yaml` | Deployment | 1 репліка, стратегія `Recreate` (том RWO), проби `pg_isready` |
| `postgres-service.yaml` | Service ClusterIP `postgres` | БД доступна лише всередині кластера |
| `backend-deployment.yaml` | Deployment | 2 репліки, `envFrom` ConfigMap+Secret, проби `/health`, requests/limits, `maxUnavailable: 0` |
| `backend-service.yaml` | Service ClusterIP `backend` | frontend звертається до `http://backend:5000` |
| `frontend-deployment.yaml` | Deployment | 2 репліки Nginx, `BACKEND_URL`, проби `/healthz` |
| `frontend-service.yaml` | Service NodePort `30080` | доступ з хоста |
| `ingress.yaml` | Ingress `library.local` | доступ через ingress-nginx |

Мітки скрізь узгоджені: selector `app.kubernetes.io/name: <компонент>` збігається з мітками шаблону пода.

### Параметри ConfigMap і Secret

| Об'єкт | Ключ | Значення | Призначення |
|---|---|---|---|
| ConfigMap | `APP_TITLE` | Онлайн бібліотека | заголовок сторінки (видно в UI та `/api/info`) |
| ConfigMap | `LOG_LEVEL` | INFO | рівень логування backend |
| ConfigMap | `DB_HOST` | postgres | ім'я Service БД |
| ConfigMap | `DB_PORT` | 5432 | порт БД |
| ConfigMap | `DB_NAME` | library | назва БД |
| ConfigMap | `DB_USER` | library | користувач БД |
| Secret | `DB_PASSWORD` | lab3-demo-password | пароль БД (не від робочої системи) |

Backend отримує всі ключі як змінні оточення (`envFrom`). PostgreSQL бере ті самі значення через `configMapKeyRef` / `secretKeyRef`.

## 2. Хід виконання (PowerShell)

### 2.1. Образи (п.1)

Образи `ghcr.io/<логін>/online-library-backend` і `…-frontend` з тегами **1.0.0** і **1.1.0** опубліковані в ЛР-2 (git-теги `v1.0.0`, `v1.1.0`). Пакети в GHCR мають бути **Public**. У маніфестах використано конкретний тег `1.0.0`, а не `latest`.

### 2.2. Кластер (п.2)

```powershell
minikube start --driver=docker
kubectl get nodes -o wide
kubectl get pods -n kube-system
minikube addons enable metrics-server
minikube addons enable ingress
minikube addons list | Select-String "metrics-server|ingress"
```

### 2.3. Розгортання однією командою (п.3, п.5a–b)

```powershell
kubectl apply -f k8s/
kubectl get pods,deployments,replicasets,services,pvc,ingress -n online-library
kubectl get pods -n online-library -w     # дочекатися Running 1/1, потім Ctrl+C
```

### 2.4. Відкрити застосунок (п.5c)

Варіант NodePort (на Windows з драйвером docker команда тримає тунель відкритим):

```powershell
minikube service frontend -n online-library
```

Варіант Ingress: додайте в `C:\Windows\System32\drivers\etc\hosts` (від імені адміністратора) рядок `127.0.0.1 library.local`, у окремому терміналі запустіть `minikube tunnel` і відкрийте http://library.local.

Додайте 2–3 книги, видайте одну.

### 2.5. ConfigMap і Secret у контейнері (п.5d)

```powershell
kubectl exec -n online-library deploy/backend -- printenv APP_TITLE LOG_LEVEL DB_HOST DB_NAME DB_USER DB_PASSWORD
kubectl exec -n online-library deploy/backend -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:5000/api/info').read().decode())"
```

### 2.6. Самовідновлення (п.6a)

```powershell
kubectl get pods -n online-library -l app.kubernetes.io/name=backend
kubectl delete pod <ім'я-одного-пода-backend> -n online-library
kubectl get pods -n online-library -l app.kubernetes.io/name=backend   # з'явився новий под (AGE кілька секунд)
```

### 2.7. Масштабування і розподіл трафіку (п.6b)

```powershell
kubectl scale deployment backend -n online-library --replicas=4
kubectl get pods -n online-library -l app.kubernetes.io/name=backend -o wide
kubectl run curl --rm -it --restart=Never -n online-library --image=curlimages/curl -- sh -c 'for i in $(seq 1 12); do curl -s http://backend:5000/health; echo; done'
```

У відповідях поле `pod` змінюється, тобто Service розподіляє запити між репліками.

### 2.8. Rolling update, історія, відкат і доступність (п.6c–e)

**Термінал 1** запускає безперервний цикл запитів:

```powershell
kubectl run watcher --rm -it --restart=Never -n online-library --image=curlimages/curl -- sh -c 'while true; do curl -s -m 2 http://backend:5000/version || echo FAIL; echo; sleep 0.5; done'
```

**Термінал 2** виконує оновлення:

```powershell
kubectl set image deployment/backend backend=ghcr.io/<логін>/online-library-backend:1.1.0 -n online-library
kubectl annotate deployment/backend -n online-library kubernetes.io/change-cause="update backend to 1.1.0" --overwrite
kubectl rollout status deployment/backend -n online-library
kubectl get rs -n online-library -l app.kubernetes.io/name=backend
kubectl rollout history deployment/backend -n online-library
kubectl rollout undo deployment/backend -n online-library --to-revision=1
kubectl rollout status deployment/backend -n online-library
kubectl rollout history deployment/backend -n online-library
```

У терміналі 1 версія плавно змінюється `1.0.0 → 1.1.0 → 1.0.0` без жодного `FAIL`. Це забезпечують `maxUnavailable: 0` і readinessProbe.

### 2.9. Діагностика (п.7)

```powershell
kubectl set image deployment/backend backend=ghcr.io/<логін>/online-library-backend:9.9.9 -n online-library
kubectl get pods -n online-library -l app.kubernetes.io/name=backend   # ErrImagePull / ImagePullBackOff
kubectl describe pod <ім'я-пода-з-помилкою> -n online-library          # розділ Events: manifest unknown / not found
kubectl get events -n online-library --sort-by=.lastTimestamp
kubectl logs deploy/backend -n online-library                          # логи робочого контейнера
kubectl exec -it deploy/backend -n online-library -- sh                # інтерактивний вхід
#   всередині:  env | grep DB_ ;  python -c "import app; print(app.APP_VERSION)" ;  exit
kubectl rollout undo deployment/backend -n online-library              # виправлення
kubectl rollout status deployment/backend -n online-library
kubectl get pods -n online-library
```

Робочі старі поди не зупинялись (`maxUnavailable: 0`), тому застосунок залишався доступним навіть під час помилки.

### 2.10. Прибирання (перед ЛР-4)

```powershell
kubectl delete -f k8s/
```

## 3. Скріншоти для звіту

| № | Файл | Що на скріншоті |
|---|---|---|
| 1 | `lab3-01-k8s-dir.png` | дерево `k8s/` у VS Code |
| 2 | `lab3-02-minikube.png` | `minikube start`, `kubectl get nodes`, поди `kube-system` |
| 3 | `lab3-03-addons.png` | увімкнені `metrics-server` та `ingress` |
| 4 | `lab3-04-apply.png` | вивід `kubectl apply -f k8s/` |
| 5 | `lab3-05-objects.png` | `kubectl get pods,deployments,replicasets,services,pvc,ingress` |
| 6 | `lab3-06-browser.png` | застосунок у браузері з книгами і бейджем `v1.0.0` |
| 7 | `lab3-07-env.png` | `printenv` з APP_TITLE, DB_* та `/api/info` |
| 8 | `lab3-08-selfheal.png` | видалення пода і новий под |
| 9 | `lab3-09-scale.png` | 4 репліки і цикл `curl` з різними `pod` |
| 10 | `lab3-10-rolling.png` | `rollout status` + два ReplicaSet |
| 11 | `lab3-11-availability.png` | термінал з циклом `/version`: 1.0.0 → 1.1.0 без FAIL |
| 12 | `lab3-12-history-undo.png` | `rollout history` до і після `undo` |
| 13 | `lab3-13-imagepullbackoff.png` | под у стані `ImagePullBackOff` |
| 14 | `lab3-14-describe-events.png` | `describe pod`, розділ Events з причиною |
| 15 | `lab3-15-logs-exec.png` | `kubectl logs` і сесія `kubectl exec -it … sh` |
| 16 | `lab3-16-fixed.png` | після виправлення всі поди `Running` |

## 4. Висновок

Застосунок описано 11 маніфестами і розгорнуто в minikube однією командою. Перевірено, що конфігурація з ConfigMap і Secret доходить до контейнерів. Показано самовідновлення, масштабування з балансуванням трафіку, rolling update без простою, відкат за історією ревізій і діагностику ImagePullBackOff через `describe`, події, логи та `exec`.
