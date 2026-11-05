# Лабораторна робота №4. Пакування застосунку в Helm-чарт

**Мета:** переписати маніфести ЛР-3 як Helm-чарт, параметризувати його для dev і prod та пройти повний життєвий цикл релізу.

## 1. Що зроблено в коді

Чарт лежить у `charts/online-library/`. Опис шаблонів і таблиця параметрів — у [README чарта](../charts/online-library/README.md).

- **Chart.yaml:** `name`, `description`, `version: 0.1.0` (версія чарта), `appVersion: "1.0.0"` (версія застосунку).
- **templates/:** кожен маніфест з `k8s/` став окремим шаблоном. Значення взято з `.Values`, імена побудовано через `include "library.componentName"` від імені релізу, тому в шаблонах немає жорстко прописаних імен, тегів чи кількості реплік.
- **Secret:** у шаблоні є лише `{{ .Values.secret.dbPassword | b64enc }}` з `required`. Сам пароль передається значеннями.
- **_helpers.tpl:** повне ім'я (`library.fullname`), набори міток (`library.labels`, `library.componentLabels`, `library.selectorLabels`), образ (`library.image`) і спільний шаблон пода backend. Усі шаблони підключають їх через `include`.
- **NOTES.txt:** після встановлення виводить, як відкрити застосунок залежно від Ingress / NodePort / ClusterIP.
- **values.yaml:** dev за замовчуванням. Для необов'язкових об'єктів є прапорці `ingress.enabled` і `postgres.persistence.enabled`.
- **values-dev.yaml / values-prod.yaml:** відрізняються репліками (1/3), ресурсами, тегом образу (1.1.0/1.0.0), Ingress (вимкн./увімк.), типом Service, PVC і рівнем логів.
- **Завдання на вибір — варіант b (хук + тест):**
  - `templates/pre-upgrade-job.yaml` — Job з анотацією `helm.sh/hook: pre-upgrade`. Перед кожним оновленням він перевіряє `pg_isready`, що БД доступна. Якщо БД недоступна, оновлення не почнеться.
  - `templates/tests/test-connection.yaml` — под з `helm.sh/hook: test`. Він звертається до `backend /health` і до `frontend → /api/books`, тобто перевіряє весь ланцюжок frontend → backend → БД.

**Пріоритет значень:** `values.yaml` у чарті має найнижчий пріоритет. Його перекривають файли `-f`, причому якщо файлів кілька, кожен наступний перекриває попередній. Найвищий пріоритет у `--set`. Наприклад, `-f values-prod.yaml --set backend.replicaCount=5` дасть 5 реплік, хоча у prod-файлі 3.

## 2. Хід виконання (PowerShell, з кореня репозиторію)

### 2.1. Середовище (п.1)

```powershell
helm version
minikube start --driver=docker
kubectl apply -f k8s/                         # перевірка, що маніфести ЛР-3 працюють
kubectl get pods -n online-library
kubectl delete -f k8s/                        # прибираємо, щоб не було конфлікту імен
```

### 2.2. Перевірка і порівняння (п.6b, п.7a–b)

```powershell
helm lint charts/online-library
helm lint charts/online-library -f charts/online-library/values-prod.yaml --set secret.dbPassword=x

helm template library charts/online-library -n online-library -f charts/online-library/values-dev.yaml > dev.yaml
helm template library charts/online-library -n online-library -f charts/online-library/values-prod.yaml --set secret.dbPassword=x > prod.yaml
code --diff dev.yaml prod.yaml               # різниця між середовищами без встановлення

helm template library charts/online-library -n online-library > rendered.yaml
code --diff k8s/backend-deployment.yaml rendered.yaml   # порівняння з маніфестами ЛР-3
```

Відмінності від ЛР-3: імена отримали префікс релізу (`library-online-library-backend`), додано мітки `helm.sh/chart`, `app.kubernetes.io/instance`, `managed-by: Helm` та анотацію `checksum/config`. Також з'явились хук і тест.

### 2.3. Встановлення (п.7c–e)

```powershell
helm install library charts/online-library -n online-library --create-namespace
kubectl get pods -n online-library -w            # чекати Running, Ctrl+C
helm list -n online-library
helm status library -n online-library
helm get values library -n online-library        # значення, задані користувачем
helm get values library -n online-library --all  # усі обчислені значення
kubectl get secrets -n online-library -l owner=helm   # sh.helm.release.v1.library.v1
```

Helm зберігає стан кожної ревізії релізу в **Secret** типу `helm.sh/release.v1` у namespace релізу. Ім'я має формат `sh.helm.release.v1.<реліз>.v<ревізія>`.

Відкрити застосунок можна командою з NOTES (`minikube service library-online-library-frontend -n online-library`).

### 2.4. Життєвий цикл (п.8)

```powershell
# a) оновлення тега через --set (спрацює хук pre-upgrade)
helm upgrade library charts/online-library -n online-library --set backend.image.tag=1.1.0
kubectl get jobs,pods -n online-library             # видно Job library-online-library-db-check
helm history library -n online-library

# b) оновлення файлом значень іншого середовища
helm upgrade library charts/online-library -n online-library -f charts/online-library/values-dev.yaml
kubectl get pods -n online-library                  # по 1 репліці, PVC не використовується

# c) історія
helm history library -n online-library
helm get values library -n online-library --revision 2
helm get values library -n online-library --revision 3

# d) відкат
helm rollback library 2 -n online-library
helm history library -n online-library             # з'явилась ревізія 4: "Rollback to 2"

# п.9b: тест релізу
helm test library -n online-library --logs

# e) видалення
helm uninstall library -n online-library
kubectl get all,cm,secret,pvc,ingress -n online-library
```

Пояснення історії:

| Ревізія | Що змінювалося |
|---|---|
| 1 | install зі значеннями за замовчуванням (тег 1.0.0) |
| 2 | `--set backend.image.tag=1.1.0` |
| 3 | `values-dev.yaml`: 1 репліка, менші ресурси, тег 1.1.0, без PVC |
| 4 | rollback до 2: Helm створює **нову** ревізію з конфігурацією ревізії 2 |

`helm upgrade` без `--reuse-values` бере значення лише з чарта і з того, що передано зараз. Тому на кроці 3 параметр `--set` з кроку 2 не зберігся.

Після `uninstall` у namespace лишається тільки системний ConfigMap `kube-root-ca.crt`, який Kubernetes створює в кожному namespace автоматично.

## 3. Скріншоти для звіту

| № | Файл | Що на скріншоті |
|---|---|---|
| 1 | `lab4-01-helm-version.png` | `helm version`, `minikube status` |
| 2 | `lab4-02-chart-tree.png` | дерево `charts/online-library/` у VS Code |
| 3 | `lab4-03-chart-yaml.png` | `Chart.yaml` (version / appVersion) |
| 4 | `lab4-04-helpers.png` | `_helpers.tpl` з іменованими шаблонами |
| 5 | `lab4-05-lint.png` | `helm lint`: 0 chart(s) failed |
| 6 | `lab4-06-diff-envs.png` | `code --diff dev.yaml prod.yaml` |
| 7 | `lab4-07-diff-lab3.png` | порівняння з маніфестом ЛР-3 |
| 8 | `lab4-08-install-notes.png` | `helm install` з виводом NOTES |
| 9 | `lab4-09-list-status-values.png` | `helm list`, `helm status`, `helm get values` |
| 10 | `lab4-10-release-secret.png` | `kubectl get secrets -l owner=helm` |
| 11 | `lab4-11-upgrade-set-hook.png` | `helm upgrade --set …` і Job db-check |
| 12 | `lab4-12-upgrade-dev.png` | upgrade з `values-dev.yaml`, поди |
| 13 | `lab4-13-history-rollback.png` | `helm history` до і після rollback |
| 14 | `lab4-14-helm-test.png` | `helm test --logs`: All checks passed |
| 15 | `lab4-15-uninstall.png` | `helm uninstall` і порожній namespace |

## 4. Висновок

Маніфести ЛР-3 перетворено на параметризований Helm-чарт зі спільними шаблонами, двома середовищами, хуком `pre-upgrade` і тестом релізу. Показано встановлення, оновлення через `--set` і файл значень, історію ревізій, відкат і видалення однією командою. Стан релізу Helm зберігає в Secret у namespace релізу.
