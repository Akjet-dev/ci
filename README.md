# Akjet CI

Общие GitHub Actions для деплоя проектов Akjet.

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

### `@v2` — деплой готового артефакта (рекомендуется)

Сборка идёт на раннере GitHub Actions. На сервере не запускаются `git`, установка зависимостей и сборка — только приём файлов и переключение симлинка.

Download artifact → NetBird → SSH → `rsync` в `releases/<sha>.partial` → `releases/<sha>` → атомарное переключение `current` → удаление старых релизов (остаются последние `keep-releases`, по умолчанию 3) → отключение NetBird.

```yaml
jobs:
  build:
    # ... собрать и загрузить: actions/upload-artifact@v4 с name: build-akjet-main
  deploy:
    needs: build
    uses: Akjet-dev/ci/.github/workflows/deploy.yml@v2
    with:
      artifact: build-akjet-main   # артефакт из этого же запуска workflow
      target: akjet                # только для имени job/concurrency
    secrets:
      NETBIRD_SETUP_KEY: ${{ secrets.NETBIRD_SETUP_KEY }}
      NETBIRD_MANAGEMENT_URL: ${{ secrets.NETBIRD_MANAGEMENT_URL }}
      DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      DEPLOY_PATH: ${{ secrets.MAIN_DEPLOY_PATH }}
```

Структура на сервере (`DEPLOY_PATH`):

```
releases/<sha>/            по каталогу на коммит
current -> releases/<sha>
production -> current      корень веб-сервера
```

Однократная миграция существующего каталога (до первого деплоя через `@v2`):

```bash
cd "$DEPLOY_PATH"
mkdir -p releases
cp -a production releases/pre-v2        # текущая версия становится первым релизом
ln -sfn releases/pre-v2 current
mv production production.bak && ln -sfn current production
```

Пока `production` — обычный каталог, деплой `@v2` завершается с ошибкой и ничего не меняет.

Откат: `ln -sfn releases/<sha> current.tmp && mv -Tf current.tmp current`.

На сервере нужны `rsync` и GNU coreutils (`mv -T`); `DEPLOY_USER` должен иметь права записи в `DEPLOY_PATH`.

### `@main` / `@v1` — сборка на сервере (устарело)

> **Deprecated.** Сборка на сервере перегружает CPU/RAM хоста. Новые проекты подключайте через `@v2`. `@main` и `@v1` пока сохраняют это поведение; ссылающимся на `@main` лучше закрепиться на `@v1`.

NetBird → SSH → `git fetch` + `reset --hard` на ветку пуша → `./bin/deploy` (если он есть в проекте) → отключение NetBird.

```yaml
jobs:
  deploy:
    uses: Akjet-dev/ci/.github/workflows/deploy.yml@v1
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

- `v2` — деплой артефакта, сборка на раннере.
- `v1` — сборка на сервере (устарело).
- `main` — ветка разработки; закрепляйтесь на тег, а не на `@main`. Изменения проверяйте в ветке, временно указав её в одном проекте.
