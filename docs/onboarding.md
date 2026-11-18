# Подключение сервиса к Kubernetes (DEV)

Примеры условные. Сервис `example-api`, организация `example-org`.

## Кто что делает

| # | Шаг | Кто |
|---|---|---|
| 1 | Dockerfile, совместимый с Kubernetes | команда сервиса |
| 2 | `deploy/values.yaml`, `deploy/values-dev.yaml` | команда сервиса |
| 3 | Два workflow-файла | команда сервиса |
| 4 | Неймспейс, квота, сетевая политика, права общего раннера, маршрут, pull-секрет | платформа |
| 5 | Secret'ы по объявлению `requiredSecrets` | платформа |
| 6 | Сборка и деплой | команда сервиса |

Чарт и общие workflow при этом не меняются.

## 1. Dockerfile

- Процесс работает от числового пользователя, не от root.
- Порты не ниже 1024.
- Запись — только в каталоги, перечисленные в `writablePaths`.
- Журнал — в stdout/stderr.
- Конфигурация — из переменных окружения, без запечённых секретов.
- Есть HTTP-адрес для проверки готовности.

## 2. Values

`deploy/values.yaml` — общее для сервиса:

```yaml
image:
  repository: ghcr.io/example-org/example-api
imagePullSecrets: [registry-pull]

config:
  LOG_CHANNEL: stderr

requiredSecrets:
  app: [APP_KEY, DB_PASSWORD]
envFromSecrets: [app]

components:
  web:
    ports: { http: 8080 }
    service: { enabled: true }
    probes:
      readiness: { path: /up, port: http }
      liveness: { path: /up, port: http }
    writablePaths: [/tmp]
    resources:
      requests: { cpu: 100m, memory: 192Mi }
      limits: { memory: 384Mi }
```

`deploy/values-dev.yaml` — отличия окружения:

```yaml
config:
  APP_ENV: dev
  DB_HOST: postgres.example.test
  DB_DATABASE: example_dev
  DB_USERNAME: example_dev_app

components:
  web:
    replicas: 1
```

Больше примеров (воркер и планировщик, миграции, секреты-файлы) — в `charts/akjet-app/ci/`.
`httpRoute` в values сервиса не включайте: маршруты создаёт платформа, а `deploy-k8s.yml` отклоняет
релиз с HTTPRoute.

Проверить локально до первого запуска:

```bash
helm template example-api oci://ghcr.io/example-org/charts/akjet-app --version 0.1.0 \
  -f deploy/values.yaml -f deploy/values-dev.yaml \
  --set-string image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
```

## 3. Workflow

Скопируйте два файла из `examples/service-repo/.github/workflows/` в `.github/workflows/` сервиса:

| Файл | Назначение |
|---|---|
| `k8s-build.yml` | push в `dev-k8s/**`, `stage-k8s/**`: тесты, проверка values, образ; публикация — только с `dev-k8s/release` и `stage-k8s/release`; деплой в DEV — только с `dev-k8s/release` |
| `k8s-deploy.yml` | ручной повторный деплой digest в DEV, только с `dev-k8s/release` |

В них нужно заменить: организацию и `<CI_COMMIT>` (полный SHA коммита общего репозитория), команду
запуска тестов, версию чарта. Существующий `deploy.yml` не трогайте и не добавляйте в него новые ветки.

Проверить, что новые workflow не пересекаются с действующим деплоем:

```bash
python3 <путь к ci>/tests/check_branch_model.py .github/workflows --legacy-branch dev/v2
```

Модель веток и порядок включения деплоя — в [ветки и деплой](branches.md).

## 4. Что нужно от платформы

Передайте платформенной команде:

- какой неймспейс нужен (или в каком существующем неймспейсе сервис будет жить рядом с другим) — затем
  его имя записывается в `deployment.namespace` values-файлов сервиса;
- порты компонентов с Service и нужен ли маршрут и на каком имени хоста (маршрут создаёт платформа);
- куда сервис ходит сам: база данных, объектное хранилище, внешние API;
- оценку ресурсов для квоты;
- объявление `requiredSecrets` — какие Secret'ы и ключи должны существовать.

Платформа создаёт неймспейс, квоту, сетевую политику, маршрут, pull-секрет реестра и выдаёт общему
раннеру `akjet-ds-apps` (ServiceAccount `arc-runners/app-deployer`) namespaced Role в этом неймспейсе.
Отдельного раннера на сервис нет.

## 5. Секреты

Значения секретов не хранятся в Git. Объект Secret `<release>-<имя>` с перечисленными в values ключами
создаёт в неймспейсе платформа. Значения либо вносит платформа, либо — для DEV — они явно перечисляются
в `app-secrets` вызывающего workflow и берутся из секретов репозитория (`docs/workflows.md`, «Секреты
приложения из GitHub»).

Добавить новую учётную запись:

1. добавить ключ в `requiredSecrets` в values (PR);
2. передать значение платформе по защищённому каналу;
3. после обновления Secret'а — деплой с `restart: true`.

## 6. Деплой

1. Создать ветку `dev-k8s/release` от `main` (вручную, по согласованию). Ветки `dev/*` для
   Kubernetes не используются.
2. Push в `dev-k8s/release` → workflow `K8s build` → образ и digest в summary.
3. Пока деплой не включён для репозитория, конвейер на этом останавливается.
4. После включения тот же push выкатывает образ в `dev-<имя репозитория>`.
5. Для отката — `K8s deploy` с предыдущим digest, с ветки `dev-k8s/release`.
