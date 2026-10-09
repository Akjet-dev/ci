# Akjet CI

Общие GitHub Actions для деплоя проектов Akjet.

## `netbird` — composite action

Ставит NetBird нужной версии, подключается и ждёт маршрут до хоста.

```yaml
- uses: Akjet-dev/ci/netbird@v1
  with:
    setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
    management-url: ${{ secrets.NETBIRD_MANAGEMENT_URL }}
    wait-for-ip: 10.128.0.5

# ... шаги, которым нужна сеть

- if: always()
  run: sudo netbird down || true
```

## `.github/workflows/deploy.yml` — reusable workflow

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

Workflow ссылается на action как `Akjet-dev/ci/netbird@v1`, поэтому тег `v1` должен указывать на коммит, где есть обе части. После изменений:

```bash
git tag -f v1 && git push -f origin v1
```
