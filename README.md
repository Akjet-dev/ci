# Akjet CI

Общие GitHub Actions для деплоя проектов Akjet.

В репозитории два независимых набора:

| Набор | Файлы | Статус |
|---|---|---|
| Деплой в Kubernetes | `charts/akjet-app/`, `.github/workflows/build-image.yml`, `deploy-k8s.yml`, `chart-ci.yml`, `examples/` | новый; деплой только в `dev` и только с ветки `dev-k8s/release`, на общем раннере `akjet-ds-apps` |
| Деплой на сервер | `.github/workflows/deploy.yml`, `netbird/` | действующий, описан ниже без изменений |

Репозиторий публичный: здесь не должно быть внутренних адресов, имён хостов, названий секретов и
других сведений о конкретных сервисах. Всё, что относится к сервису, живёт в его репозитории.

## Kubernetes: общий чарт и reusable workflow

- [Чарт `akjet-app`](docs/chart.md) — структура values, ссылки на секреты, маршруты, миграции.
- [Workflow](docs/workflows.md) — интерфейс `build-image.yml` и `deploy-k8s.yml`, работа с digest,
  требования к раннеру, права деплоя, ограничения GitHub Free.
- [Подключение сервиса](docs/onboarding.md) — что делает команда сервиса и что нужно от платформы.
- [Ветки и деплой](docs/branches.md) — какие ветки что запускают и как новый конвейер сосуществует
  с действующим деплоем на сервер.

Коротко:

- образ собирается один раз и деплоится только по digest (`sha256:…`), теги не принимаются;
- неймспейс вычисляется как `<environment>-<имя репозитория>` и не задаётся вызывающим;
- деплой выполняет общий раннер `akjet-ds-apps` внутри кластера под ServiceAccount'ом
  `arc-runners/app-deployer`; kubeconfig и секреты приложений в GitHub Actions не используются;
- ветки Kubernetes — `dev-k8s/**` и `stage-k8s/**`; ветки `dev/*` и `main` их не запускают;
- маршруты (HTTPRoute) создаёт платформа, релиз приложения их не содержит;
- чарт только ссылается на существующие Kubernetes Secret'ы и не создаёт их.

Перед первым деплоем сервиса платформа должна подготовить: неймспейс с квотой и сетевой политикой,
namespaced Role общего раннера в этом неймспейсе, маршрут, pull-секрет реестра и Secret'ы приложения.
Опубликованный чарт появляется после тега `chart-akjet-app-<версия>`.

### Тесты

```bash
tests/run.sh
```

Нужны `helm`, `kubeconform`, `actionlint`, `yq`, `python3`. Набор офлайн: lint и рендер всех примеров
из `charts/akjet-app/ci/`, проверка манифестов по схемам Kubernetes, проверки безопасности
(`tests/policy_check.py`), отрицательные примеры из `tests/invalid/`, проверка workflow.

## `netbird` — composite action

Ставит NetBird нужной версии, подключается и ждёт маршрут до хоста.

```yaml
- uses: Akjet-dev/ci/netbird@main
  with:
    setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
    management-url: ${{ secrets.NETBIRD_MANAGEMENT_URL }}
    wait-for-ip: 10.128.0.5

# ... шаги, которым нужна сеть

- if: always()
  run: sudo netbird down || true
```

## `.github/workflows/deploy.yml` — reusable workflow

> **Deprecated.** Описанный ниже вариант собирает проект на сервере и перегружает его CPU/RAM. Используйте `@v2`: сборка идёт на раннере, на сервер приезжает готовый артефакт (`rsync` → `releases/<sha>` → атомарное переключение `current`). Документация и миграция — в README тега [`v2`](https://github.com/Akjet-dev/ci/blob/v2/README.md). `@main` и `@v1` пока сохраняют старое поведение; ссылающимся на `@main` лучше закрепиться на `@v1`.

NetBird → SSH → `git fetch` + `reset --hard` на ветку пуша → `./bin/deploy` (если он есть в проекте) → отключение NetBird.

```yaml
jobs:
  deploy:
    uses: Akjet-dev/ci/.github/workflows/deploy.yml@main
    with:
      repo: Akjet-dev/backend
      # target: akjet   # уходит в bin/deploy как DEPLOY_TARGET
    secrets:
      NETBIRD_SETUP_KEY: ${{ secrets.NETBIRD_SETUP_KEY }}
      NETBIRD_MANAGEMENT_URL: ${{ secrets.NETBIRD_MANAGEMENT_URL }}
      DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      DEPLOY_PATH: ${{ github.ref_name == 'main' && secrets.MAIN_DEPLOY_PATH || secrets.DEV_DEPLOY_PATH }}
```

В `bin/deploy` доступны `DEPLOY_REPO`, `DEPLOY_BRANCH`, `DEPLOY_PATH`, `DEPLOY_TARGET`.

## Версии

Проекты и сам workflow ссылаются на `@main`: любой пуш в `main` этого репозитория сразу применяется ко всем деплоям. Изменения лучше проверять в ветке, временно указав её в одном проекте вместо `@main`.
