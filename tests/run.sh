#!/usr/bin/env bash
# Offline test suite of the shared chart and the reusable workflows. Nothing here talks to a cluster,
# a registry or GitHub.
#
#   tests/run.sh
#
# Tools (override with environment variables): HELM, KUBECONFORM, ACTIONLINT, yq, python3.
# KUBERNETES_VERSION   schema version for kubeconform (default 1.35.6)
# SCHEMA_DIR           optional directory with offline schemas:
#                        $SCHEMA_DIR/k8s/<kind>-<group>-<version>.json   (standalone-strict layout)
#                        $SCHEMA_DIR/gateway.networking.k8s.io/<kind>_<version>.json
#                      without it kubeconform downloads the public schemas.
set -euo pipefail

cd "$(dirname "$0")/.."

HELM="${HELM:-helm}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
ACTIONLINT="${ACTIONLINT:-actionlint}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35.6}"
CHART=charts/akjet-app
RELEASE=example
NAMESPACE=dev-example
WORK="$(mktemp -d "${TMPDIR:-/tmp}/akjet-ci.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

if [ -n "${SCHEMA_DIR:-}" ]; then
  schema_args=(
    -schema-location "${SCHEMA_DIR}/k8s/{{ .ResourceKind }}{{ .KindSuffix }}.json"
    -schema-location "${SCHEMA_DIR}/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json"
  )
else
  schema_args=(
    -schema-location default
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  )
fi

render() { "$HELM" template "$RELEASE" "$CHART" --namespace "$NAMESPACE" "$@"; }

echo "== tools"
"$HELM" version --short
"$KUBECONFORM" -v
"$ACTIONLINT" -version | head -1

echo "== valid fixtures: lint, render, schema validation, security checks"
for values in "$CHART"/ci/*-values.yaml; do
  name="$(basename "$values" -values.yaml)"
  out="$WORK/$name.yaml"
  if "$HELM" lint "$CHART" --strict -f "$values" >"$WORK/lint.log" 2>&1; then
    pass "$name: helm lint --strict"
  else
    fail "$name: helm lint --strict"; cat "$WORK/lint.log"
  fi
  if ! render -f "$values" >"$out" 2>"$WORK/render.log"; then
    fail "$name: helm template"; cat "$WORK/render.log"; continue
  fi
  pass "$name: helm template"
  if "$KUBECONFORM" -strict -summary -kubernetes-version "$KUBERNETES_VERSION" "${schema_args[@]}" "$out" >"$WORK/kubeconform.log" 2>&1; then
    pass "$name: kubeconform -strict ($(tail -1 "$WORK/kubeconform.log"))"
  else
    fail "$name: kubeconform -strict"; cat "$WORK/kubeconform.log"
  fi
  if yq ea -o=json '[.]' "$out" | python3 tests/policy_check.py --name "$name" >"$WORK/policy.log" 2>&1; then
    pass "$name: $(cat "$WORK/policy.log")"
  else
    fail "$name: security checks"; cat "$WORK/policy.log"
  fi
  # No secret material: the chart never renders a Secret object or a literal credential.
  if grep -Eq '^kind: Secret$' "$out"; then fail "$name: a Secret object was rendered"; fi
done

echo "== behaviour"
expect_kinds() {  # label, expected sorted "Kind/name" list, helm args...
  local label="$1" expected="$2"; shift 2
  local got
  got="$(render "$@" | yq ea -N '[.kind + "/" + .metadata.name] | .[]' - | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$expected" ]; then pass "$label"; else fail "$label: got '$got', expected '$expected'"; fi
}
expect_kinds "static frontend renders exactly ServiceAccount, Deployment, Service" \
  "Deployment/example-web Service/example-web ServiceAccount/example" \
  -f "$CHART/ci/01-static-frontend-values.yaml"
expect_kinds "HTTPRoute is not rendered unless httpRoute.enabled" \
  "Deployment/example-web Service/example-web ServiceAccount/example" \
  -f "$CHART/ci/06-httproute-values.yaml" --set httpRoute.enabled=false
expect_kinds "worker and scheduler get no Service" \
  "ConfigMap/example-config Deployment/example-scheduler Deployment/example-web Deployment/example-worker Service/example-web ServiceAccount/example" \
  -f "$CHART/ci/03-laravel-web-worker-scheduler-values.yaml"
expect_kinds "migration Job is not part of a normal release (render=false)" \
  "ConfigMap/example-config Deployment/example-web Service/example-web ServiceAccount/example" \
  -f "$CHART/ci/04-migration-job-values.yaml" --set migration.render=false
expect_kinds "migration Job can be rendered alone" \
  "Job/example-migrate-42-1" \
  -f "$CHART/ci/04-migration-job-values.yaml" --set-string migration.runId=42-1 --show-only templates/migration-job.yaml

job="$(render -f "$CHART/ci/04-migration-job-values.yaml" --show-only templates/migration-job.yaml)"
if [ "$(echo "$job" | yq '.spec.template.spec.containers[0].env[] | select(.name == "DB_USERNAME") | .value')" = "example_dev_migrator" ]; then
  pass "migration.config overrides the release config (migrator role)"
else
  fail "migration.config does not override the release config"
fi
if [ "$(echo "$job" | yq '[.spec.template.spec.containers[0].envFrom[].secretRef.name] | join(",")')" = "example-app,example-migrate" ]; then
  pass "migration Job references Secrets by name, migration-specific last"
else
  fail "migration Job Secret references"
fi

sched="$(render -f "$CHART/ci/03-laravel-web-worker-scheduler-values.yaml" | yq 'select(.kind == "Deployment" and .metadata.name == "example-scheduler")')"
if [ "$(echo "$sched" | yq '.spec.strategy.type')" = "Recreate" ] && [ "$(echo "$sched" | yq '.spec.replicas')" = "1" ]; then
  pass "scheduler uses Recreate with one replica"
else
  fail "scheduler strategy"
fi

a="$(render -f "$CHART/ci/02-laravel-api-values.yaml" | yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/config"')"
b="$(render -f "$CHART/ci/02-laravel-api-values.yaml" --set-string config.NEW_FEATURE_FLAG=on | yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/config"')"
if [ -n "$a" ] && [ "$a" != "$b" ]; then
  pass "a new variable needs only values (and rolls the pods: config checksum changes)"
else
  fail "config checksum does not change with config"
fi

c="$(render -f "$CHART/ci/02-laravel-api-values.yaml" --set-string rolloutRevision=run-1 | yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."akjet.kz/rollout-revision"')"
if [ "$c" = "run-1" ]; then pass "rolloutRevision restarts pods without an image change"; else fail "rolloutRevision annotation"; fi

echo "== invalid fixtures must be rejected"
for values in tests/invalid/*.yaml; do
  name="$(basename "$values" .yaml)"
  expected="$(sed -n 's/^# expect: //p' "$values" | head -1)"
  if render -f "$values" >/dev/null 2>"$WORK/invalid.log"; then
    fail "$name: was accepted"
  elif grep -qF -- "$expected" "$WORK/invalid.log"; then
    pass "$name: rejected ($expected)"
  else
    fail "$name: rejected for another reason than '$expected'"; cat "$WORK/invalid.log"
  fi
done

echo "== workflows"
templates=(examples/service-repo/.github/workflows/k8s-build.yml examples/service-repo/.github/workflows/k8s-deploy.yml)
if "$ACTIONLINT" -color=false .github/workflows/*.yml "${templates[@]}" >"$WORK/actionlint.log" 2>&1; then
  pass "actionlint: $(find .github/workflows -name '*.yml' | wc -l | tr -d ' ') workflow files and ${#templates[@]} templates"
else
  fail "actionlint"; cat "$WORK/actionlint.log"
fi
new_workflows=(.github/workflows/build-image.yml .github/workflows/deploy-k8s.yml .github/workflows/chart-ci.yml)
if grep -nE 'uses: +[^ ]+@' "${new_workflows[@]}" | grep -vE '@[0-9a-f]{40}( |$)' >"$WORK/pins.log"; then
  fail "actions must be pinned to a full commit SHA"; cat "$WORK/pins.log"
else
  pass "every action is pinned to a full commit SHA"
fi
if grep -nE 'secrets: *inherit|pull_request_target' "${new_workflows[@]}" "${templates[@]}" >"$WORK/wf.log"; then
  fail "secrets: inherit / pull_request_target are not allowed"; cat "$WORK/wf.log"
else
  pass "no 'secrets: inherit', no pull_request_target"
fi
if [ "$(cat "${new_workflows[@]}" | grep -cE '^permissions:')" = "${#new_workflows[@]}" ]; then
  pass "every new workflow declares top-level permissions"
else
  fail "top-level permissions missing in a workflow"
fi

echo "== deploy-k8s.yml: what can be deployed, and from where"
dk=.github/workflows/deploy-k8s.yml
if grep -niE '(^|[^a-z])(prod|production)([^a-z]|$)' "$dk" "${templates[@]}" .github/workflows/build-image.yml >"$WORK/env.log"; then
  fail "the Kubernetes workflows must not mention production"; cat "$WORK/env.log"
else
  pass "no production target anywhere in the Kubernetes workflows and templates"
fi
inputs="$(yq '.on.workflow_call.inputs | keys | join(" ")' "$dk")"
case " $inputs " in
  *" namespace "*|*runner*|*" branch "*|*" service "*|*" kubeconfig "*|*" cluster "*) fail "deploy-k8s.yml exposes an input that selects the target: $inputs" ;;
  *) pass "no input selects the namespace, the runner, the cluster or the deployment branch ($inputs)" ;;
esac
if [ "$(yq '.on.workflow_call.secrets // {} | keys | join(",")' "$dk")" = "app-secrets,env-bundle" ] \
   && [ "$(yq '.on.workflow_call.secrets.app-secrets.required' "$dk")" = "false" ] \
   && [ "$(yq '.on.workflow_call.secrets.env-bundle.required' "$dk")" = "false" ]; then
  pass "deploy-k8s.yml accepts exactly two secrets, both optional: app-secrets and env-bundle"
else
  fail "deploy-k8s.yml: secrets contract"
fi
deploy_if="$(yq '.jobs.deploy.if' "$dk" | tr '\n' ' ')"
ok_if=true
for guard in "needs.validate.outputs.deploy == 'true'" "!inputs.validate-only" "inputs.environment == 'dev'" \
             "github.ref == 'refs/heads/dev-k8s/release'" "vars.K8S_DEV_DEPLOY_ENABLED == 'true'"; do
  case "$deploy_if" in *"$guard"*) ;; *) ok_if=false; echo "      missing in jobs.deploy.if: $guard" ;; esac
done
case "$deploy_if" in *"||"*) ok_if=false ;; esac
if $ok_if; then pass "the deploy job is guarded by environment, branch, validate-only and the repository switch (AND only)"; else fail "deploy job guard"; fi
if [ "$(yq '.jobs.deploy.env.ENVIRONMENT' "$dk")" = "dev" ] && [ "$(yq '.jobs.deploy.env.HELM_DRIVER' "$dk")" = "configmap" ]; then
  pass "the deploy job is hard-wired to dev and stores releases in ConfigMaps"
else
  fail "deploy job environment / HELM_DRIVER"
fi
if yq '.jobs.validate.steps[].run // ""' "$dk" | grep -qE 'kubectl|helm (upgrade|install|rollback|uninstall)'; then
  fail "the validate job must not touch a cluster"
else
  pass "the validate job (GitHub-hosted) never calls kubectl or a mutating helm command"
fi

resolve="$(yq '.jobs.validate.steps[0].run' "$dk")"
runner_label="$(yq '.env.RUNNER_LABEL' "$dk")"
deploy_branch="$(yq '.env.DEV_DEPLOY_BRANCH' "$dk")"
if [ "$runner_label" = "akjet-ds-apps" ] && [ "$deploy_branch" = "dev-k8s/release" ]; then
  pass "fixed contract: shared runner akjet-ds-apps, DEV deployment branch dev-k8s/release"
else
  fail "fixed contract: RUNNER_LABEL='$runner_label' DEV_DEPLOY_BRANCH='$deploy_branch'"
fi
# shellcheck disable=SC2016  # the GitHub expression is compared literally
if [ "$(yq '.jobs.deploy.runs-on' "$dk")" = '${{ needs.validate.outputs.runner }}' ] \
   && ! grep -q 'RUNNER_PREFIX' "$dk"; then
  pass "the deploy job runs on the runner resolved from RUNNER_LABEL; no per-service runner derivation"
else
  fail "deploy job runs-on / per-service runner derivation"
fi
kinds_case="$(yq '.jobs.validate.steps[] | select(.name == "Validate manifests") | .run' "$dk" | grep -E '^ *ConfigMap\|' | tr -d ' ')"
if [ "$kinds_case" = "ConfigMap|ServiceAccount|Deployment|Service|Job);;" ]; then
  pass "an application release may render only ConfigMap, ServiceAccount, Deployment, Service, Job (no HTTPRoute)"
else
  fail "allowed kinds in deploy-k8s.yml: '$kinds_case'"
fi
good_digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
# environment ref event validate-only [digest] [release] [values-dir] [chart] [repository] [chart-version] [app-secrets supplied]
run_resolve() {
  : >"$WORK/gh_output"
  local repo="${9:-Example-Org/example-api}"
  env -i PATH="$PATH" GITHUB_OUTPUT="$WORK/gh_output" GITHUB_REPOSITORY="$repo" GITHUB_REPOSITORY_OWNER="${repo%%/*}" \
    RUNNER_LABEL="$runner_label" DEV_DEPLOY_BRANCH="$deploy_branch" \
    ENVIRONMENT="$1" GITHUB_REF="$2" GITHUB_EVENT_NAME="$3" VALIDATE_ONLY="$4" DIGEST="${5-$good_digest}" \
    RELEASE_INPUT="${6:-}" VALUES_DIR="${7:-deploy}" CHART_INPUT="${8:-}" CHART_VERSION="${10:-1.2.3}" \
    APP_SECRETS_SUPPLIED="${11:-false}" ENV_BUNDLE_SUPPLIED="${12:-false}" \
    TIMEOUT="10m" DEPLOY_ENABLED="true" bash -c "$resolve" >"$WORK/resolve.log" 2>&1
}
out() { grep -qx "$1" "$WORK/gh_output"; }
accept() {  # label, expected output line, args...
  local label="$1" line="$2"; shift 2
  if run_resolve "$@" && out "$line"; then pass "$label"; else fail "$label"; cat "$WORK/resolve.log" "$WORK/gh_output"; fi
}
reject() {
  local label="$1"; shift
  if run_resolve "$@"; then fail "accepted: $label"; else pass "rejected: $label"; fi
}

accept "push to dev-k8s/release deploys to dev" "deploy=true" dev refs/heads/dev-k8s/release push false
if out "runner=akjet-ds-apps" && out "chart=oci://ghcr.io/example-org/charts/akjet-app" && ! grep -qE '^(namespace|release)=' "$WORK/gh_output"; then
  pass "the target check decides environment, branch, runner and chart only - it resolves no namespace and no release"
else
  fail "derived target"; cat "$WORK/gh_output"
fi
accept "the runner label does not depend on the repository" "runner=akjet-ds-apps" dev refs/heads/dev-k8s/release push false "$good_digest" "" deploy "" Example-Org/other-service
accept "manual run on dev-k8s/release deploys to dev" "deploy=true" dev refs/heads/dev-k8s/release workflow_dispatch false
accept "other dev-k8s/* branch: validation only, no deployment" "deploy=false" dev refs/heads/dev-k8s/feature-x push true ""
accept "stage-k8s/release: stage values are validated, no deployment" "deploy=false" stage refs/heads/stage-k8s/release push true ""

reject "deploy to dev from main" dev refs/heads/main push false
reject "deploy to dev from dev/v1" dev refs/heads/dev/v1 push false
reject "deploy to dev from dev/v2" dev refs/heads/dev/v2 push false
reject "deploy to dev from dev/clockster" dev refs/heads/dev/clockster push false
reject "deploy to dev from the old branch dev/k8s" dev refs/heads/dev/k8s push false
reject "deploy to dev from dev-k8s/feature-x" dev refs/heads/dev-k8s/feature-x push false
reject "deploy to dev from dev-k8s/release/nested" dev refs/heads/dev-k8s/release/nested push false
reject "deploy to dev from stage-k8s/release" dev refs/heads/stage-k8s/release push false
reject "deploy to dev from dev-k8s-copy" dev refs/heads/dev-k8s-copy push false
reject "deploy to dev from a tag named like the branch" dev refs/tags/dev-k8s/release push false
reject "deploy to dev on a pull_request event" dev refs/heads/dev-k8s/release pull_request false
reject "deploy to stage from stage-k8s/release" stage refs/heads/stage-k8s/release push false
reject "deploy to stage from dev-k8s/release" stage refs/heads/dev-k8s/release push false
reject "deploy to stage by manual run" stage refs/heads/stage-k8s/release workflow_dispatch false
reject "environment prod" prod refs/heads/main push false
reject "environment prod, validation only" prod refs/heads/main push true ""
reject "environment 'dev-other' (namespace injection)" dev-other refs/heads/dev-k8s/release push false
reject "mutable tag instead of digest" dev refs/heads/dev-k8s/release push false latest
reject "deployment without a digest" dev refs/heads/dev-k8s/release push false ""
reject "truncated digest" dev refs/heads/dev-k8s/release push false sha256:abc
reject "floating chart version" dev refs/heads/dev-k8s/release push false "$good_digest" "" deploy "" "" 1.x
reject "values-dir outside the repository" dev refs/heads/dev-k8s/release push false "$good_digest" "" ../other
reject "chart from an arbitrary URL" dev refs/heads/dev-k8s/release push false "$good_digest" "" deploy https://example.test/chart.tgz

echo "== deploy-k8s.yml: namespace and release come only from the values of the service"
id_step="$(yq '.jobs.validate.steps[] | select(.id == "identity") | .run' "$dk")"
idw="$WORK/identity"
id_values() {  # common values.yaml text, env file text, [environment=dev]
  rm -rf "$idw"; mkdir -p "$idw/deploy"
  printf '%s\n' "$1" >"$idw/deploy/values.yaml"; printf '%s\n' "$2" >"$idw/deploy/values-${3:-dev}.yaml"
}
id_run() {  # environment, [release input], [env-bundle-secret input], [repository] -> outputs in $WORK/id_output
  : >"$WORK/id_output"
  ( cd "$idw" && env -i PATH="$PATH" RUNNER_TEMP="$idw/tmp" GITHUB_OUTPUT="$WORK/id_output" GITHUB_REPOSITORY="${4:-Example-Org/example-api}" \
      ENVIRONMENT="$1" TIMEOUT=10m VALUES_DIR=deploy RELEASE_INPUT="${2:-}" BUNDLE_SECRET_INPUT="${3:-}" bash --noprofile --norc -c "$id_step" ) </dev/null >"$WORK/id.log" 2>&1
}
id_out() { sed -n "s/^$1=//p" "$WORK/id_output"; }
id_reject() {  # label, expected text, id_run args
  local label="$1" text="$2"; shift 2
  if id_run "$@"; then fail "accepted: $label"
  elif grep -qF -- "$text" "$WORK/id.log"; then pass "rejected before any cluster access: $label"
  else fail "rejected for another reason: $label"; cat "$WORK/id.log"; fi
}
base_common='deployment:
  release: example-api
image: { repository: ghcr.io/example-org/example-api }
components:
  web:
    ports: { http: 8080 }'
id_values "$base_common" $'deployment:\n  namespace: dev-somewhere-else\nconfig:\n  A: "1"'
if id_run dev && [ "$(id_out namespace)/$(id_out release)/$(id_out bundle-secret)" = "dev-somewhere-else/example-api/" ]; then
  pass "namespace and release are exactly the values' deployment.namespace / deployment.release (nothing derived from the repository name)"
else
  fail "identity from values"; cat "$WORK/id.log"
fi
first="$(cat "$WORK/id_output")"
if id_run dev "" "" Other-Org/completely-different && [ "$(cat "$WORK/id_output")" = "$first" ] && ! grep -q 'GITHUB_REPOSITORY' <<<"$id_step"; then
  pass "the same values give the same target from any repository: the identity step does not read the repository name"
else
  fail "the repository name influences the target"
fi
if [ "$(yq -o=json -I0 '.' "$idw/tmp/values/values.yaml")" = '{"image":{"repository":"ghcr.io/example-org/example-api"},"components":{"web":{"ports":{"http":8080}}}}' ] \
   && [ "$(yq -o=json -I0 '.' "$idw/tmp/values/values-dev.yaml")" = '{"config":{"A":"1"}}' ]; then
  pass "Helm receives copies of both values files without the deployment block and otherwise unchanged"
else
  fail "values copies for Helm"; cat "$idw/tmp/values/"*
fi
id_values "$base_common" $'deployment:\n  namespace: stage-somewhere\n' stage
if id_run stage && [ "$(id_out namespace)" = "stage-somewhere" ]; then pass "stage: the namespace comes from values-stage.yaml"; else fail "stage namespace from values"; cat "$WORK/id.log"; fi
id_values "$base_common" $'config:\n  A: "1"'
id_reject "deployment.namespace missing" "deployment.namespace is not set in deploy/values.yaml or deploy/values-dev.yaml" dev
if ! grep -q '^namespace=' "$WORK/id_output"; then pass "  ... and no namespace is guessed (no default, no runner namespace)"; else fail "a namespace was guessed"; fi
id_values "$base_common" $'deployment:\n  namespace: arc-runners'
id_reject "the runner's own namespace" "does not belong to the environment dev" dev
id_values "$base_common" $'deployment:\n  namespace: stage-example-api'
id_reject "a STAGE namespace in the DEV values (DEV/STAGE isolation)" "deployment.namespace 'stage-example-api' does not belong to the environment dev" dev
id_values "$base_common" $'config: {}' stage
printf 'deployment:\n  namespace: dev-example-api\n' >"$idw/deploy/values-dev.yaml"
id_reject "values-stage.yaml without its own namespace (the DEV one is never reused)" "deployment.namespace is not set in deploy/values.yaml or deploy/values-stage.yaml" stage
id_values "$base_common" $'deployment:\n  namespace: dev-'
id_reject "the bare environment prefix" "is not a valid namespace name" dev
id_values "$base_common" $'deployment:\n  namespace: Dev_Example'
id_reject "an invalid namespace name" "is not a valid namespace name" dev
id_values "$base_common" "deployment:
  namespace: dev-$(printf 'x%.0s' $(seq 1 60))"
id_reject "a namespace longer than 63 characters" "is not a valid namespace name" dev
id_values "$base_common" $'deployment:\n  namespace: 5'
id_reject "a namespace that is not a string" "deployment.namespace, deployment.release and deployment.envBundle.secret must be strings" dev
id_values 'deployment: {}' $'deployment:\n  namespace: dev-example-api'
id_reject "deployment.release missing" "deployment.release is not set" dev
id_values $'deployment:\n  release: "x;id"' $'deployment:\n  namespace: dev-example-api'
id_reject "a release with shell metacharacters" "deployment.release 'x;id' must match" dev
id_values $'deployment:\n  release: example-api\n  kubeContext: other' $'deployment:\n  namespace: dev-example-api'
id_reject "an unknown key under deployment" "deployment: unknown key(s) kubeContext" dev
id_values $'deployment:\n  release: example-api\n  envBundle: { secret: app, extra: 1 }' $'deployment:\n  namespace: dev-example-api'
id_reject "an unknown key under deployment.envBundle" "deployment.envBundle: unknown key(s) extra" dev
id_values $'deployment: [1]' $'config: {}'
id_reject "deployment that is not a map" "must be a map" dev
id_values "$base_common" $'deployment:\n  namespace: dev-example-api'
id_reject "a deprecated release input that contradicts the values" "input release 'other' contradicts deployment.release 'example-api'" dev other
if id_run dev example-api && [ "$(id_out release)" = "example-api" ]; then pass "a deprecated release input equal to the values is accepted"; else fail "release input equal to values"; fi
id_values $'deployment:\n  release: example-api\n  envBundle:\n    secret: app' $'deployment:\n  namespace: dev-example-api'
if id_run dev && [ "$(id_out bundle-secret)" = "app" ]; then pass "the env-bundle target Secret is declared in the values (deployment.envBundle.secret)"; else fail "envBundle.secret from values"; fi
id_reject "an env-bundle-secret input that contradicts the values" "contradicts deployment.envBundle.secret 'app'" dev "" other
id_values "$base_common" $'deployment:\n  namespace: dev-example-api'
if id_run dev "" app && [ "$(id_out bundle-secret)" = "app" ] && grep -q 'input env-bundle-secret is deprecated' "$WORK/id.log"; then
  pass "the deprecated env-bundle-secret input still works when the values declare nothing (with a warning)"
else fail "deprecated env-bundle-secret input"; fi
id_values $'deployment:\n  release: example-api\n  envBundle:\n    secret: "app;x"' $'deployment:\n  namespace: dev-example-api'
id_reject "an invalid env-bundle Secret name" "is not a Secret name of requiredSecrets" dev

# the real consumers, when the workspace holds them: their namespaces and releases come from their own values
if [ -d ../backend/deploy ] && [ -d ../lk-frontend/deploy ]; then
  ws_id() {  # repository directory, environment -> "namespace release"
    : >"$WORK/id_output"
    ( cd "$1" && env -i PATH="$PATH" RUNNER_TEMP="$WORK/ws-id" GITHUB_OUTPUT="$WORK/id_output" ENVIRONMENT="$2" TIMEOUT=10m VALUES_DIR=deploy \
        RELEASE_INPUT="" BUNDLE_SECRET_INPUT="" bash --noprofile --norc -c "$id_step" ) </dev/null >/dev/null 2>&1 || { echo error; return; }
    echo "$(id_out namespace) $(id_out release)"
  }
  if [ "$(ws_id ../backend dev)" = "dev-lk-backend backend" ] && [ "$(ws_id ../lk-frontend dev)" = "dev-lk-backend lk-frontend" ] \
     && [ "$(ws_id ../backend stage)" = "stage-lk-backend backend" ] && [ "$(ws_id ../lk-frontend stage)" = "stage-lk-backend lk-frontend" ]; then
    pass "backend and lk-frontend declare the same namespace and two separate releases, in DEV and in STAGE"
  else
    fail "backend / lk-frontend identity: $(ws_id ../backend dev) | $(ws_id ../lk-frontend dev)"
  fi
fi

echo "== deploy-k8s.yml and build-image.yml know no service"
services='backend|lk-frontend|executor-frontend|landing|bcc-kommo-api|lk-backend'
if grep -nE "(^|[^a-z-])($services)([^a-z-]|$)" "$dk" .github/workflows/build-image.yml | grep -v '^\S*:[0-9]*: *#' >"$WORK/names.log"; then
  fail "a shared workflow names a service"; cat "$WORK/names.log"
else
  pass "no service name, namespace or release of a consumer appears in the logic of the shared workflows"
fi
kube_lines="$(yq '.jobs.deploy.steps[] | select(.run != null) | .run' "$dk" | grep -E '(^|[|(] *|; *|\$\( *)(kubectl|helm) ' | grep -vE 'curl|registry (login|logout)|helm pull|command -v|kubectl auth can-i "?(create|get|list|patch)"? (deployments|configmaps|jobs|secrets)' || true)"
# shellcheck disable=SC2016  # literal workflow text
missing_ns="$(grep -E '(kubectl|helm) ' <<<"$kube_lines" | grep -v -- '--namespace "${NAMESPACE}"' | grep -vE '^\s*(echo|#)|^\s*helm "\$\{args\[@\]\}"$' || true)"
# shellcheck disable=SC2016  # literal workflow text
if ! grep -q 'upgrade --install "${RELEASE}" "${CHART_DIR}" --namespace "${NAMESPACE}"' "$dk"; then missing_ns="${missing_ns} helm upgrade"; fi
if [ -z "$missing_ns" ]; then
  pass "every kubectl / helm command of the deploy job names --namespace \"\${NAMESPACE}\" explicitly"
else
  fail "kubectl / helm commands without the resolved namespace"; echo "$missing_ns"
fi
if grep -nE 'dry-run=client|arc-runners|current-context|config view' <<<"$(yq '.jobs[].steps[] | select(.run != null) | .run' "$dk" | grep -vE '^\s*#')"; then
  fail "the deploy workflow relies on a client-side namespace default"
else
  pass "no client-side dry run, kubeconfig context or runner namespace is used to place an object"
fi

# Two releases in one namespace: no object of one release may carry the name of an object of the other.
"$HELM" template backend "$CHART" --namespace dev-lk-backend -f tests/secrets/deploy/values.yaml -f tests/secrets/deploy/values-dev.yaml >"$WORK/shared-a.yaml"
"$HELM" template lk-frontend "$CHART" --namespace dev-lk-backend -f tests/overrides/deploy/values.yaml -f tests/overrides/deploy/values-dev.yaml >"$WORK/shared-b.yaml"
objs() { yq ea -N 'select(. != null) | .kind + "/" + .metadata.name' "$1" | sort; }
if [ -z "$(comm -12 <(objs "$WORK/shared-a.yaml") <(objs "$WORK/shared-b.yaml"))" ] \
   && ! objs "$WORK/shared-a.yaml" | grep -qv '/backend\(-\|$\)' && ! objs "$WORK/shared-b.yaml" | grep -qv '/lk-frontend\(-\|$\)'; then
  pass "two releases in one namespace: every object name starts with its release name, none is shared"
else
  fail "two releases in one namespace share an object name"; objs "$WORK/shared-a.yaml"; objs "$WORK/shared-b.yaml"
fi
sel_of() { yq ea -N -o=json -I0 'select(.kind == "Deployment" or .kind == "Service") | (.spec.selector.matchLabels // .spec.selector)' "$1" | sort -u; }
if ! sel_of "$WORK/shared-a.yaml" | grep -qv '"app.kubernetes.io/instance":"backend"' \
   && ! sel_of "$WORK/shared-b.yaml" | grep -qv '"app.kubernetes.io/instance":"lk-frontend"'; then
  pass "two releases in one namespace: every Deployment and Service selects pods of its own release only"
else
  fail "selectors do not include the release"; sel_of "$WORK/shared-a.yaml"; sel_of "$WORK/shared-b.yaml"
fi
# shellcheck disable=SC2016  # literal workflow text
if [ "$(grep -c -- '--selector "app.kubernetes.io/instance=${RELEASE}"' "$dk")" = "2" ] \
   && [ "$(grep -c 'sel="app.kubernetes.io/instance=${RELEASE}"' "$dk")" = "1" ]; then
  pass "rollout check and diagnostics look only at objects of the deployed release"
else
  fail "rollout check / diagnostics are not limited to the release"
fi
rel=(dev refs/heads/dev-k8s/release push false "$good_digest")
reject "app-secrets passed to a validation-only run" dev refs/heads/dev-k8s/feature-x push true "" "" deploy "" Akjet-dev/backend "" true
reject "app-secrets passed to stage validation" stage refs/heads/stage-k8s/release push true "" "" deploy "" Akjet-dev/backend "" true
accept "app-secrets passed to the deploying run" "deploy=true" "${rel[@]}" "" deploy "" Akjet-dev/backend "" true

echo "== deploy-k8s.yml: private chart registry"
for job in validate deploy; do
  if [ "$(yq ".jobs.$job.permissions.packages" "$dk")" = "read" ] && [ "$(yq ".jobs.$job.permissions.contents" "$dk")" = "read" ] \
     && [ "$(yq ".jobs.$job.permissions | length" "$dk")" = "2" ]; then
    pass "job $job: permissions are exactly contents: read and packages: read"
  else
    fail "job $job: permissions"
  fi
done
pull_steps="$(yq '[.jobs[].steps[] | select(.run != null and (.run | test("helm pull")))] | length' "$dk")"
# shellcheck disable=SC2016  # the yq expression contains literal ${...} text
auth_steps="$(yq '[.jobs[].steps[] | select(.run != null and (.run | test("helm pull")) and (.run | test("helm registry login ghcr.io --username \"\\$\\{GITHUB_ACTOR\\}\" --password-stdin")) and (.run | test("helm registry logout ghcr.io")) and .env.GITHUB_TOKEN == "${{ github.token }}")] | length' "$dk")"
if [ "$pull_steps" = "2" ] && [ "$auth_steps" = "2" ]; then
  pass "both steps that pull the chart log in to ghcr.io with the job token (stdin) and log out again"
else
  fail "chart pull authentication: $auth_steps of $pull_steps steps"
fi
if grep -nE 'helm registry login[^|]*--password[ =]|secrets\.[A-Za-z_]*(PAT|TOKEN)' "$dk" >"$WORK/pat.log"; then
  fail "the chart login must use the job token on stdin, no PAT and no --password argument"; cat "$WORK/pat.log"
else
  pass "no personal access token and no password on a command line"
fi
tpl_ok=true
for tpl in "${templates[@]}"; do
  missing="$(yq '[.jobs[] | select(.uses != null and (.uses | test("/deploy-k8s.yml@")) and (.permissions.packages != "read" or .permissions.contents != "read"))] | length' "$tpl")"
  [ "$missing" = "0" ] || { tpl_ok=false; echo "      $tpl: $missing calling job(s) without contents: read + packages: read"; }
done
if $tpl_ok; then pass "templates: every job calling deploy-k8s.yml grants contents: read and packages: read"; else fail "template caller permissions"; fi

echo "== build-image.yml: which branches may publish"
names="$(yq '.jobs.build.steps[] | select(.id == "names") | .run' .github/workflows/build-image.yml)"
publish_branches="$(yq '.env.PUBLISH_BRANCHES' .github/workflows/build-image.yml)"
mkdir -p "$WORK/src/deploy" && : >"$WORK/src/Dockerfile"
printf 'image:\n  repository: ghcr.io/example-org/declared-image\n' >"$WORK/src/deploy/values.yaml"
push_decision() {  # ref-name ref-type push-input [image input] [values-dir]
  : >"$WORK/gh_output"
  ( cd "$WORK/src" && env -i PATH="$PATH" GITHUB_OUTPUT="$WORK/gh_output" GITHUB_REPOSITORY="Example-Org/example-api" \
      GITHUB_REPOSITORY_OWNER="Example-Org" PUBLISH_BRANCHES="$publish_branches" GITHUB_REF_NAME="$1" GITHUB_REF_TYPE="$2" \
      IMAGE_INPUT="${4:-}" VALUES_DIR="${5:-deploy}" CONTEXT="." DOCKERFILE="Dockerfile" PLATFORM="linux/amd64" PUSH_INPUT="$3" SCAN_FAIL_ON="CRITICAL" \
      bash -c "$names" >"$WORK/names.log" 2>&1 ) || { echo error; return; }
  sed -n 's/^push=//p' "$WORK/gh_output"
}
expect_push() {  # expected ref-name ref-type push-input
  local got; got="$(push_decision "$2" "$3" "$4")"
  if [ "$got" = "$1" ]; then pass "publish=$1 for $3 $2 (push input: $4)"; else fail "publish for $2: got '$got', expected '$1'"; fi
}
expect_push true  dev-k8s/release branch true
expect_push true  stage-k8s/release branch true
expect_push false dev-k8s/release branch false
expect_push false main branch true
expect_push false dev/v1 branch true
expect_push false dev/v2 branch true
expect_push false dev/k8s branch true
expect_push false stage/k8s branch true
expect_push false dev-k8s/feature-example branch true
expect_push false stage-k8s/feature-example branch true
expect_push false dev-k8s/release/nested branch true
expect_push false dev-k8s-release branch true
expect_push false dev-k8s/release tag true
push_decision dev-k8s/release branch true >/dev/null
if out "image=ghcr.io/example-org/declared-image"; then
  pass "the image is image.repository of the service values (ghcr.io/example-org/declared-image), not the repository name"
else
  fail "image from values"; cat "$WORK/names.log"
fi
if [ "$(push_decision dev-k8s/release branch true declared-image)" = "true" ] && out "image=ghcr.io/example-org/declared-image"; then
  pass "a deprecated image input that names the same image is accepted"
else fail "image input equal to values"; fi
image_reject() {  # label, expected text, push_decision args
  local label="$1" text="$2"; shift 2
  if [ "$(push_decision "$@")" != "error" ]; then fail "accepted: $label"
  elif grep -qF -- "$text" "$WORK/names.log"; then pass "rejected: $label"
  else fail "rejected for another reason: $label"; cat "$WORK/names.log"; fi
}
image_reject "an image input that contradicts the values" "input image builds ghcr.io/example-org/example-api, but deploy/values.yaml deploys ghcr.io/example-org/declared-image" dev-k8s/release branch true example-api
image_reject "no image anywhere (nothing is derived from the repository name)" "no image: set image.repository in nowhere/values.yaml" dev-k8s/release branch true "" nowhere
printf 'image:\n  repository: ghcr.io/other-org/foreign\n' >"$WORK/src/deploy/values.yaml"
image_reject "an image outside the owner's registry namespace" "must be a repository under ghcr.io/example-org/" dev-k8s/release branch true
printf 'image:\n  repository: ghcr.io/example-org/declared-image:latest\n' >"$WORK/src/deploy/values.yaml"
image_reject "an image repository with a tag" "lower case, no tag or digest" dev-k8s/release branch true
printf 'image:\n  repository: ghcr.io/example-org/declared-image\n' >"$WORK/src/deploy/values.yaml"
if [ "$(yq '.on.workflow_call.secrets | keys | join(",")' .github/workflows/build-image.yml)" = "build-secrets" ] \
   && [ "$(yq '.on.workflow_call.secrets.build-secrets.required' .github/workflows/build-image.yml)" = "false" ]; then
  pass "build-image.yml accepts one optional, explicitly passed secret and no runtime credentials"
else
  fail "build-image.yml secrets interface"
fi

echo "== build-image.yml: vulnerability scan (advisory / strict)"
bi=.github/workflows/build-image.yml
scan="$(yq '.jobs.build.steps[] | select(.id == "scan") | .run' "$bi")"
mkdir -p "$WORK/trivy-bin" && cp tests/fixtures/trivy "$WORK/trivy-bin/trivy"
run_scan() {  # fake-trivy-mode block-on-cves scan-fail-on
  : >"$WORK/scan_summary"; : >"$WORK/scan_output"; rm -f "$WORK/trivy-report.json"
  env -i PATH="$WORK/trivy-bin:$PATH" RUNNER_TEMP="$WORK" GITHUB_STEP_SUMMARY="$WORK/scan_summary" \
    GITHUB_OUTPUT="$WORK/scan_output" GITHUB_SHA=0000000 IMAGE=ghcr.io/example-org/example-api \
    FAKE_TRIVY="$1" TRIVY_BLOCK_ON_CVES="$2" SCAN_FAIL_ON="$3" bash -c "$scan" >"$WORK/scan.log" 2>&1
}
scan_case() {  # label, expected (pass|block), expected text in the log, mode, block, fail-on
  local label="$1" expected="$2" text="$3" rc=0; shift 3
  run_scan "$@" || rc=$?
  if { [ "$expected" = "pass" ] && [ "$rc" -eq 0 ]; } || { [ "$expected" = "block" ] && [ "$rc" -ne 0 ]; }; then
    if grep -qF -- "$text" "$WORK/scan.log"; then pass "$label"; else fail "$label: '$text' not in the log"; cat "$WORK/scan.log"; fi
  else
    fail "$label: exit code $rc, expected $expected"; cat "$WORK/scan.log"
  fi
}
scan_case "advisory: CRITICAL vulnerabilities do not stop the build" pass "ADVISORY MODE: 2 fixable vulnerabilities" critical false HIGH,CRITICAL
if grep -qx 'critical=1' "$WORK/scan_output" && grep -qx 'high=2' "$WORK/scan_output" \
   && grep -q 'CRITICAL vulnerabilities | 1' "$WORK/scan_summary" && grep -q 'HIGH vulnerabilities | 2' "$WORK/scan_summary" \
   && grep -q 'findings: mode=critical' "$WORK/scan.log" && jq -e '.Results[0].Vulnerabilities | length == 3' "$WORK/trivy-report.json" >/dev/null; then
  pass "advisory: findings stay visible (scanner output in the log, counts in the summary and outputs, JSON report kept)"
else
  fail "advisory: findings are not visible"; cat "$WORK/scan_summary" "$WORK/scan_output"
fi
scan_case "advisory: CRITICAL gate severity only - still does not stop the build" pass "ADVISORY MODE: 1 fixable vulnerabilities" critical false CRITICAL
scan_case "advisory: HIGH vulnerabilities do not stop the build" pass "ADVISORY MODE: 2 fixable vulnerabilities" high false HIGH,CRITICAL
scan_case "advisory: a clean image passes without a warning" pass "Trivy: CRITICAL=0 HIGH=0" clean false CRITICAL
scan_case "advisory: scanner failure is an error, not a finding" block "Trivy failed to scan the image" fail false CRITICAL
scan_case "advisory: failure while writing the report is an error" block "Trivy failed to write the scan report" fail-json false CRITICAL
scan_case "advisory: an unreadable report is an error" block "report is missing or not valid" garbage false CRITICAL
scan_case "advisory: embedded secrets still stop the build" block "embedded secret(s)" secret false CRITICAL
scan_case "strict: embedded secrets stop the build" block "embedded secret(s)" secret true CRITICAL
scan_case "strict: CRITICAL vulnerabilities stop the build" block "fixable vulnerabilities of severity CRITICAL; it is not published" critical true CRITICAL
scan_case "strict: HIGH vulnerabilities stop the build when HIGH is a gate severity" block "it is not published" high true HIGH,CRITICAL
scan_case "strict: HIGH vulnerabilities pass when only CRITICAL is a gate severity" pass "Trivy: CRITICAL=0 HIGH=2" high true CRITICAL
scan_case "strict: vulnerabilities without a fix are reported, not blocking" pass "Trivy: CRITICAL=1 HIGH=0 fixable=0" unfixed true CRITICAL
scan_case "strict: a clean image passes" pass "Trivy: CRITICAL=0 HIGH=0" clean true CRITICAL
scan_case "strict: scanner failure is an error" block "Trivy failed to scan the image" fail true CRITICAL

if [ "$(yq '.env.TRIVY_BLOCK_ON_CVES' "$bi")" = "false" ] && [ "$(grep -cE '^\s*TRIVY_BLOCK_ON_CVES:' "$bi")" = "1" ]; then
  pass "TRIVY_BLOCK_ON_CVES is 'false' (advisory) and is defined in exactly one line"
else
  fail "TRIVY_BLOCK_ON_CVES must be defined once, currently 'false'"
fi
if grep -nE 'continue-on-error' "$bi" >"$WORK/coe.log" || echo "$scan" | grep -nE 'trivy .*\|\| *true|set \+e' >>"$WORK/coe.log"; then
  fail "scanner failures must not be hidden (continue-on-error / || true)"; cat "$WORK/coe.log"
else
  pass "no continue-on-error and no '|| true' around the scanner"
fi
if echo "$scan" | grep -q -- '--severity "HIGH,CRITICAL"' && ! echo "$scan" | grep -q -- '--ignore-unfixed' \
   && echo "$scan" | grep -q -- '--scanners "vuln,secret"'; then
  pass "the scan still covers HIGH and CRITICAL vulnerabilities and secrets, nothing is filtered out"
else
  fail "scan coverage changed"
fi
order="$(yq '[.jobs.build.steps[].name] | join(" > ")' "$bi")"
case "$order" in
  *"Build > Install Trivy > Scan for vulnerabilities > Keep the scan report > Push"*) pass "order: build, scan, keep the report, then push" ;;
  *) fail "step order: $order" ;;
esac
if [ "$(yq '.jobs.build.steps[] | select(.name == "Push") | .if' "$bi")" = "steps.names.outputs.push == 'true'" ]; then
  pass "publication depends only on the branch decision and on the previous steps succeeding"
else
  fail "Push step condition changed"
fi

echo "== deploy-k8s.yml: optional overrides by repository variables"
ov_step="$(yq '.jobs.validate.steps[] | select(.id == "overrides") | .run' "$dk")"
ov_src=tests/overrides
resolve_overrides() {  # environment, repository-variables JSON, [directory with deploy/]
  local dir="${3:-$ov_src}"
  : >"$WORK/ov_output"; : >"$WORK/ov_summary"; rm -f "$WORK/overrides.json"
  ( cd "$dir" && env -i PATH="$PATH" RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/ov_output" GITHUB_STEP_SUMMARY="$WORK/ov_summary" \
      ENVIRONMENT="$1" VALUES_DIR=deploy REPOSITORY_VARIABLES="$2" bash -c "$ov_step" ) >"$WORK/ov.log" 2>&1
}
ov_json() { sed -n 's/^json=//p' "$WORK/ov_output"; }
ov_expect() {  # label, expected JSON, environment, variables
  local label="$1" want="$2"; shift 2
  if resolve_overrides "$@" && [ "$(ov_json)" = "$want" ]; then pass "$label"; else fail "$label: got '$(ov_json)'"; cat "$WORK/ov.log"; fi
}
ov_reject() {  # label, expected text, environment, variables, [dir]
  local label="$1" text="$2"; shift 2
  if resolve_overrides "$@"; then fail "accepted: $label ($(ov_json))"
  elif grep -qF -- "$text" "$WORK/ov.log"; then pass "rejected: $label"
  else fail "rejected for another reason: $label"; cat "$WORK/ov.log"; fi
}
render_ov() {  # environment -> rendered manifest with the overrides of $WORK/overrides.json
  render -f "$ov_src/deploy/values.yaml" -f "$ov_src/deploy/values-$1.yaml" -f "$WORK/overrides.json"
}
config_of() { yq 'select(.kind == "ConfigMap") | .data' -o=json -I0; }
base_dev="$(render -f "$ov_src/deploy/values.yaml" -f "$ov_src/deploy/values-dev.yaml")"
base_stage="$(render -f "$ov_src/deploy/values.yaml" -f "$ov_src/deploy/values-stage.yaml")"

ov_expect "no variables: nothing is overridden" '{}' dev '{}'
if [ "$(render_ov dev)" = "$base_dev" ]; then pass "no variables: the rendered release is byte-identical to the values files alone"; else fail "empty overrides change the release"; fi
ov_expect "variables context unavailable (null): nothing is overridden" '{}' dev 'null'
ov_expect "unrelated variables (deployment switch) are ignored" '{}' dev '{"K8S_DEV_DEPLOY_ENABLED":"true","OTHER":"x"}'
ov_expect "empty variable: the values file is kept" '{}' dev '{"DEV_DB_HOST":""}'

ov_expect "DEV_DB_HOST overrides only config.DB_HOST" '{"config":{"DB_HOST":"pg.override.example.test"}}' dev '{"DEV_DB_HOST":"pg.override.example.test"}'
got="$(render_ov dev | config_of)"; want="$(echo "$base_dev" | config_of | jq -c '.DB_HOST = "pg.override.example.test"')"
if [ "$got" = "$want" ] && [ "$(render_ov dev | yq 'select(.kind != "ConfigMap" and .kind != "Deployment")' )" = "$(echo "$base_dev" | yq 'select(.kind != "ConfigMap" and .kind != "Deployment")')" ]; then
  pass "DEV: only DB_HOST differs in the ConfigMap; APP_ENV, DB_PORT and every other object are unchanged"
else
  fail "DEV override changed something else"; echo "$got"
fi
ov_expect "a DEV variable does not reach STAGE" '{}' stage '{"DEV_DB_HOST":"pg.override.example.test"}'
if [ "$(render_ov stage)" = "$base_stage" ]; then pass "STAGE release is unchanged by DEV variables"; else fail "DEV variable changed STAGE"; fi
ov_expect "STAGE_DB_HOST overrides only STAGE" '{"config":{"DB_HOST":"pg.stage-override.example.test"}}' stage '{"STAGE_DB_HOST":"pg.stage-override.example.test","DEV_DB_HOST":"pg.override.example.test"}'
if [ "$(render_ov stage | config_of | jq -r .DB_HOST)" = "pg.stage-override.example.test" ] && [ "$(render_ov stage | config_of | jq -r .APP_URL)" = "https://api.stage.example.test" ]; then
  pass "STAGE: DB_HOST from the variable, APP_URL from values-stage.yaml"
else
  fail "STAGE override"
fi
ov_expect "a STAGE variable does not reach DEV" '{}' dev '{"STAGE_DB_HOST":"pg.stage-override.example.test"}'

ov_expect "types: url, integer and boolean are validated and stored as ConfigMap strings" \
  '{"config":{"APP_URL":"https://api.other.example.test/base","DB_POOL_SIZE":"12","FEATURE_PREVIEW":"true","SERVICE_LABEL":"blue green"}}' \
  dev '{"DEV_APP_URL":"https://api.other.example.test/base","DEV_DB_POOL_SIZE":"12","DEV_FEATURE_PREVIEW":"true","DEV_SERVICE_LABEL":"blue green"}'
if render_ov dev >/dev/null 2>"$WORK/ov-render.log"; then pass "typed overrides pass the chart schema"; else fail "typed overrides rejected by the chart"; cat "$WORK/ov-render.log"; fi
ov_reject "integer variable with text" "not an integer" dev '{"DEV_DB_POOL_SIZE":"twelve"}'
ov_reject "boolean variable 'yes'" "must be true or false" dev '{"DEV_FEATURE_PREVIEW":"yes"}'
ov_reject "url variable without http(s)" "not an http(s) URL" dev '{"DEV_APP_URL":"javascript:alert(1)"}'
ov_reject "host variable with shell text" "not a host name or address" dev '{"DEV_DB_HOST":"a; rm -rf /"}'
ov_reject "variable with a line break" "control characters" dev "$(printf '{"DEV_SERVICE_LABEL":"a\\nb"}')"
ov_reject "variable of this environment that is not allowed" "DEV_FEATURE_WRITES_ENABLED are not listed" dev '{"DEV_FEATURE_WRITES_ENABLED":"true"}'
ov_reject "variable aimed at a credential" "DEV_DB_PASSWORD are not listed" dev '{"DEV_DB_PASSWORD":"x"}'

bad_allow() {  # label, expected text, overrides.yaml body
  local label="$1" text="$2" dir="$WORK/ov-bad"
  rm -rf "$dir"; mkdir -p "$dir/deploy"; printf '%s\n' "$3" >"$dir/deploy/overrides.yaml"
  ov_reject "$label" "$text" dev '{"DEV_X":"1"}' "$dir"
}
bad_allow "allow-list entry for the image digest" "only config.<NAME> can be overridden" 'overrides: { X: { path: image.digest } }'
bad_allow "allow-list entry for replicas" "only config.<NAME> can be overridden" 'overrides: { X: { path: components.web.replicas, type: integer } }'
bad_allow "allow-list entry for Secret references" "only config.<NAME> can be overridden" 'overrides: { X: { path: envFromSecrets } }'
bad_allow "allow-list entry for a component (nested path)" "only config.<NAME> can be overridden" 'overrides: { X: { path: config.A.b } }'
bad_allow "allow-list entry for the security context" "only config.<NAME> can be overridden" 'overrides: { X: { path: podSecurity.runAsUser, type: integer } }'
bad_allow "allow-list entry for a password" "looks like a credential" 'overrides: { X: { path: config.DB_PASSWORD } }'
bad_allow "allow-list entry for an API token" "looks like a credential" 'overrides: { X: { path: config.PARTNER_API_TOKEN } }'
bad_allow "allow-list entry with an unknown type" "unknown type" 'overrides: { X: { path: config.X, type: json } }'
bad_allow "allow-list entry with extra keys" "only path and type are allowed" 'overrides: { X: { path: config.X, default: "1" } }'
bad_allow "allow-list with another top-level key" 'only the top-level keys "overrides", "secrets" and "locked" are allowed' 'namespace: other'

mkdir -p "$WORK/ov-none/deploy"
ov_expect "service without overrides.yaml: mechanism is inactive even if DEV_* variables exist" '{}' dev '{"DEV_ANYTHING":"x"}' "$WORK/ov-none"
mkdir -p "$WORK/ov-rules/deploy"; printf 'secrets:\n  aliases:\n    DB_MIGRATOR_PASSWORD: migrate.DB_PASSWORD\n' >"$WORK/ov-rules/deploy/overrides.yaml"
ov_expect "overrides.yaml with bundle rules only (no 'overrides' key): the variable mechanism stays inactive" '{}' dev '{"DEV_ANYTHING":"x"}' "$WORK/ov-rules"
printf 'overrides: {}\n' >"$WORK/ov-rules/deploy/overrides.yaml"
ov_reject "an explicit empty allow-list still refuses unknown variables" "DEV_ANYTHING are not listed in overrides.yaml" dev '{"DEV_ANYTHING":"x"}' "$WORK/ov-rules"

resolve_overrides dev '{"DEV_DB_HOST":"pg.override.example.test"}'
if [ "$(jq -c 'keys' "$WORK/overrides.json")" = '["config"]' ] && ! grep -qiE 'password|secret|token' "$WORK/overrides.json" \
   && [ ! -e "$WORK/repository-variables.json" ]; then
  pass "the generated file contains only the config key, no credentials; the variables dump is removed"
else
  fail "generated overrides content"
fi
# the deploy job receives the validated JSON through a job output and writes it unchanged
apply_step="$(yq '.jobs.deploy.steps[] | select(.name == "Apply variable overrides") | .run' "$dk")"
mkdir -p "$WORK/deploy-side"
env -i PATH="$PATH" RUNNER_TEMP="$WORK/deploy-side" OVERRIDES="$(ov_json)" bash -c "$apply_step"
env -i PATH="$PATH" RUNNER_TEMP="$WORK/deploy-side-empty" OVERRIDES="" bash -c "mkdir -p \"\$RUNNER_TEMP\"; $apply_step"
# shellcheck disable=SC2016  # literal GitHub expressions
if [ "$(jq -c . "$WORK/deploy-side/overrides.json")" = "$(jq -c . "$WORK/overrides.json")" ] && [ "$(jq -c . "$WORK/deploy-side-empty/overrides.json")" = '{}' ] \
   && [ "$(yq '.jobs.validate.outputs.overrides' "$dk")" = '${{ steps.overrides.outputs.json }}' ] \
   && [ "$(yq '.jobs.deploy.steps[] | select(.name == "Apply variable overrides") | .env.OVERRIDES' "$dk")" = '${{ needs.validate.outputs.overrides }}' ]; then
  pass "deploy job applies exactly the JSON the validate job resolved (empty -> {})"
else
  fail "overrides hand-over between validate and deploy"
fi
uses_values="$(yq '[.jobs[].steps[] | select(.run != null) | .run | select(test("values-\\$\\{ENVIRONMENT\\}.yaml\"")) | select(test("helm (template|\"\\$\\{args)") or test("upgrade --install"))] | length' "$dk")"
# shellcheck disable=SC2016  # literal shell text of the workflow
uses_overrides="$(grep -c -- '-f "${RUNNER_TEMP}/overrides.json"' "$dk")"
# shellcheck disable=SC2016
if [ "$uses_overrides" = "3" ] && [ "$(grep -c -- '-f "${values}/values.yaml" -f "${values}/values-${ENVIRONMENT}.yaml"' "$dk")" = "3" ] \
   && [ "$(grep -c 'values="${RUNNER_TEMP}/values"' "$dk")" = "3" ]; then
  pass "validation render, migration render and helm upgrade all load the values copies (without deployment), then the overrides ($uses_values steps)"
else
  fail "overrides are not applied in every helm invocation ($uses_overrides of 3)"
fi
if yq '.jobs[].steps[] | select(.run != null) | .run' "$dk" | grep -nE '\$\{\{ *(vars|toJSON)' >"$WORK/interp.log"; then
  fail "repository variables must not be interpolated into a script"; cat "$WORK/interp.log"
else
  pass "repository variables reach the script only as data (environment variable with JSON)"
fi
if [ "$(render_ov dev | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image')" = "$(echo "$base_dev" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image')" ] \
   && [ "$(render_ov dev | yq 'select(.kind == "Deployment") | [.spec.template.spec.containers[0].envFrom[] | select(.secretRef != null) | .secretRef.name] | join(",")' | tr -d '\n')" = "example-app" ]; then
  pass "image digest and Secret references are untouched by overrides"
else
  fail "overrides changed the image or the Secret references"
fi

echo "== deploy-k8s.yml: GitHub secrets -> Kubernetes Secrets (app-secrets)"
sec_src=tests/secrets
decl_step="$(yq '.jobs.validate.steps[] | select(.id == "declared") | .run' "$dk")"
declared() {  # environment -> list
  : >"$WORK/decl_output"
  ( cd "$sec_src" && env -i PATH="$PATH" GITHUB_OUTPUT="$WORK/decl_output" ENVIRONMENT="$1" VALUES_DIR=deploy bash -c "$decl_step" ) >"$WORK/decl.log" 2>&1 \
    && sed -n 's/^list=//p' "$WORK/decl_output"
}
dev_declared="$(declared dev)"
if [ "$dev_declared" = "app.APP_KEY app.DB_PASSWORD migrate.DB_PASSWORD" ]; then
  pass "declared Secret keys of dev come from requiredSecrets ($dev_declared)"
else
  fail "declared Secret keys of dev: '$dev_declared'"; cat "$WORK/decl.log"
fi
if [ "$(declared stage)" = "app.APP_KEY app.DB_PASSWORD app.AWS_ACCESS_KEY_ID app.AWS_SECRET_ACCESS_KEY migrate.DB_PASSWORD integrations.PARTNER_API_TOKEN" ]; then
  pass "declared Secret keys follow Helm precedence: the environment file replaces a list and adds a Secret"
else
  fail "declared Secret keys of stage: '$(declared stage)'"
fi
# shellcheck disable=SC2016  # literal workflow text
if [ "$(yq '.jobs.validate.outputs.declared-secrets' "$dk")" = '${{ steps.declared.outputs.list }}' ] \
   && [ "$(yq '.jobs.deploy.steps[] | select(.id == "secrets") | .env.DECLARED' "$dk")" = '${{ needs.validate.outputs.declared-secrets }}' ]; then
  pass "the deploy job receives the declared keys from the validate job (names only)"
else
  fail "hand-over of the declared Secret keys"
fi
# shellcheck disable=SC2016  # literal workflow text
if [ "$(grep -c 'secrets\.app-secrets' "$dk")" = "2" ] \
   && [ "$(yq '.jobs.validate.steps[0].env.APP_SECRETS_SUPPLIED' "$dk")" = '${{ secrets.app-secrets != '"''"' }}' ] \
   && [ "$(yq '[.jobs.deploy.steps[] | select(.env.APP_SECRETS != null)] | length' "$dk")" = "1" ] \
   && [ "$(yq '[.jobs.validate.steps[] | select(.env.APP_SECRETS != null)] | length' "$dk")" = "0" ]; then
  pass "secret values reach exactly one step of the deploy job; the validate job only learns whether they were passed"
else
  fail "where app-secrets is referenced"
fi
sec_step="$(yq '.jobs.deploy.steps[] | select(.id == "secrets") | .run' "$dk")"
if grep -qE 'GITHUB_STEP_SUMMARY|set -x|tee |> *"\$\{RUNNER_TEMP' <<<"$sec_step"; then
  fail "the Secret step writes to the summary, a file or a trace"
else
  pass "the Secret step writes nothing to the summary or to files and has no command trace"
fi

# A stand-in for kubectl: Secret objects are files in $FAKE_STATE (<name>.json = data, <name>.rv = resourceVersion).
fakebin="$WORK/fakebin"; mkdir -p "$fakebin"
cat >"$fakebin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "kubectl $*" >>"$FAKE_STATE/calls.log"
case "$*" in
  "auth can-i "*)
    obj="$4"; verb="$3"
    case " ${FAKE_DENY:-} " in *" ${verb}:${obj#secret/} "*) exit 1 ;; esac
    exit 0 ;;
  *" get secret "*)
    name="$5"
    case "${FAKE_GET:-}" in
      forbidden) echo "Error from server (Forbidden): secrets \"$name\" is forbidden: User cannot get resource" >&2; exit 1 ;;
      unreachable) echo "Unable to connect to the server: EOF" >&2; exit 1 ;;
    esac
    test -f "$FAKE_STATE/$name.rv" || { echo "Error from server (NotFound): secrets \"$name\" not found" >&2; exit 1; }
    cat "$FAKE_STATE/$name.rv" ;;
  *" create -f -")
    doc="$(cat)"; name="$(jq -r '.metadata.name' <<<"$doc")"
    [ "$(jq -r '.kind + "/" + .apiVersion + "/" + .type' <<<"$doc")" = "Secret/v1/Opaque" ] || { echo "error: not an Opaque Secret" >&2; exit 1; }
    case "${FAKE_CREATE:-}" in
      forbidden) echo "Error from server (Forbidden): secrets is forbidden: User cannot create resource" >&2; exit 1 ;;
      race) printf '{"OTHER_WRITER":"b3RoZXI="}' >"$FAKE_STATE/$name.json"; echo 5 >"$FAKE_STATE/$name.rv" ;;   # someone created it first
    esac
    if [ -f "$FAKE_STATE/$name.rv" ]; then echo "Error from server (AlreadyExists): secrets \"$name\" already exists" >&2; exit 1; fi
    jq -cS '.data' <<<"$doc" >"$FAKE_STATE/$name.json"; echo 1 >"$FAKE_STATE/$name.rv"; echo created >>"$FAKE_STATE/$name.created"
    echo "secret/$name created" ;;
  *" patch secret "*" --type=merge --patch-file=/dev/stdin")
    name="$5"; doc="$(cat)"
    case "${FAKE_PATCH:-}" in forbidden) echo "Error from server (Forbidden): secrets \"$name\" is forbidden: User cannot patch resource" >&2; exit 1 ;; esac
    test -f "$FAKE_STATE/$name.rv" || { echo "Error from server (NotFound): secrets \"$name\" not found" >&2; exit 1; }
    [ "$(jq -c 'keys' <<<"$doc")" = '["data"]' ] || { echo "error: the patch must carry data only" >&2; exit 1; }
    old="$(cat "$FAKE_STATE/$name.json" 2>/dev/null || echo '{}')"; [ -n "$old" ] || old='{}'
    new="$(jq -cS -n --argjson a "$old" --argjson b "$(jq -c '.data' <<<"$doc")" '$a + $b')"
    if [ "$new" != "$(jq -cS . <<<"$old")" ]; then printf '%s' "$new" >"$FAKE_STATE/$name.json"; echo $(( $(cat "$FAKE_STATE/$name.rv") + 1 )) >"$FAKE_STATE/$name.rv"; fi
    echo "secret/$name patched" ;;
  *" apply --server-side --field-manager=akjet-app-secrets --force-conflicts -f -")
    doc="$(cat)"; name="$(jq -r '.metadata.name' <<<"$doc")"
    [ "$(jq -r '.kind + "/" + .apiVersion' <<<"$doc")" = "Secret/v1" ] || exit 1
    test -f "$FAKE_STATE/$name.rv" || { echo "forbidden: cannot create" >&2; exit 1; }
    new="$(jq -cS '.data' <<<"$doc")"
    if [ "$new" != "$(cat "$FAKE_STATE/$name.json" 2>/dev/null)" ]; then
      printf '%s' "$new" >"$FAKE_STATE/$name.json"; echo $(( $(cat "$FAKE_STATE/$name.rv") + 1 )) >"$FAKE_STATE/$name.rv"
    fi
    echo "secret/$name serverside-applied" ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$fakebin/kubectl"
sec_state="$WORK/sec-state"
sec_reset() { rm -rf "$sec_state"; mkdir -p "$sec_state"; for n in "$@"; do echo 1 >"$sec_state/$n.rv"; done; : >"$sec_state/calls.log"; }
provision() {  # app-secrets text, [declared list], [denied "verb:name ..."]
  : >"$WORK/sec_output"
  env -i PATH="$fakebin:$PATH" GITHUB_OUTPUT="$WORK/sec_output" RUNNER_TEMP="$WORK" FAKE_STATE="$sec_state" FAKE_DENY="${3:-}" \
    NAMESPACE=dev-example-api RELEASE=example-api VALUES_DIR=deploy ENVIRONMENT=dev \
    APP_SECRETS="$1" DECLARED="${2-$dev_declared}" bash --noprofile --norc -c "$sec_step" </dev/null >"$WORK/sec.log" 2>&1
}
sec_data() { jq -r --arg k "$2" '.[$k] // "" | @base64d' "$sec_state/$1.json" 2>/dev/null; }
sec_reject() {  # label, expected text, provision args...
  local label="$1" text="$2"; shift 2
  if provision "$@"; then fail "accepted: $label"
  elif ! grep -qF -- "$text" "$WORK/sec.log"; then fail "rejected for another reason: $label"; cat "$WORK/sec.log"
  elif grep -q ' apply ' "$sec_state/calls.log"; then fail "$label: a Secret was written before the failure"
  else pass "rejected, nothing written: $label"; fi
}

sec_reset example-api-app example-api-migrate
if provision "" && [ "$(cat "$WORK/sec_output")" = "changed=false" ] && [ ! -s "$sec_state/calls.log" ]; then
  pass "no app-secrets: the cluster is not contacted and Secrets stay as they are"
else
  fail "empty app-secrets"; cat "$WORK/sec.log"
fi
# shellcheck disable=SC2016  # a literal value with shell metacharacters, on purpose
pw='p@ss w0rd=with/=signs+"quotes"$HOME'
mig='M1gr@tor-0nly'
mapping="$(printf 'app.DB_PASSWORD=%s\nmigrate.DB_PASSWORD=%s\napp.APP_KEY?=\n' "$pw" "$mig")"
if provision "$mapping" && [ "$(sec_data example-api-app DB_PASSWORD)" = "$pw" ] && [ "$(sec_data example-api-migrate DB_PASSWORD)" = "$mig" ] \
   && [ "$(jq -c 'keys' "$sec_state/example-api-app.json")" = '["DB_PASSWORD"]' ] && [ "$(cat "$WORK/sec_output")" = "changed=true" ]; then
  pass "mapped values are written to the declared keys of <release>-<secret>, byte for byte; separate application and migration passwords"
else
  fail "provisioning of mapped values"; grep -v 'add-mask' "$WORK/sec.log"; cat "$sec_state/calls.log"
fi
if grep -qF 'Skipped (optional, not set): app.APP_KEY' "$WORK/sec.log"; then
  pass "an optional key (?=) with an empty value is skipped and its key is not touched"
else
  fail "optional key handling"; grep -v 'add-mask' "$WORK/sec.log"
fi
if [ "$(grep -cF -- "$pw" "$WORK/sec.log")" = "1" ] && grep -qF -- "::add-mask::$pw" "$WORK/sec.log" \
   && [ "$(grep -cF -- "$mig" "$WORK/sec.log")" = "1" ] && grep -qF -- "::add-mask::$mig" "$WORK/sec.log" \
   && ! grep -qF -- "$pw" "$WORK/sec_output" "$sec_state/calls.log" && ! grep -rqF -- "$pw" "$WORK"/*.json 2>/dev/null \
   && ! grep -qF "$(printf '%s' "$pw" | base64 | tr -d '\n')" "$WORK/sec.log" "$WORK/sec_output" "$sec_state/calls.log"; then
  pass "a value appears only in its masking command: not in the log, the output, a command line or a file"
else
  fail "a secret value leaked"; grep -v 'add-mask' "$WORK/sec.log"
fi
if [ "$(grep -c '^::add-mask::' "$WORK/sec.log")" = "2" ] && [ "$(grep -n -m1 ' apply ' "$sec_state/calls.log" | cut -d: -f1)" -gt "$(grep -c 'auth can-i' "$sec_state/calls.log")" ]; then
  pass "every value is masked, and all permissions are checked before the first write"
else
  fail "masking / order of permission checks"; cat "$sec_state/calls.log"
fi
if provision "$mapping" && [ "$(cat "$WORK/sec_output")" = "changed=false" ]; then
  pass "unchanged values: the Secrets are not modified and no restart is requested"
else
  fail "second run with the same values"; cat "$WORK/sec_output"
fi
if provision "$(printf 'app.DB_PASSWORD=%s\n' 'rotated')" && [ "$(cat "$WORK/sec_output")" = "changed=true" ] && [ "$(sec_data example-api-app DB_PASSWORD)" = "rotated" ]; then
  pass "a rotated value updates the Secret and requests a restart of the pods"
else
  fail "rotation"
fi
# shellcheck disable=SC2016  # literal workflow text
if [ "$(yq '.jobs.deploy.steps[] | select(.name == "Helm upgrade") | .env.SECRETS_CHANGED' "$dk")" = '${{ steps.secrets.outputs.changed }}' ] \
   && grep -qF 'if [ "${RESTART}" = "true" ] || [ "${SECRETS_CHANGED}" = "true" ]; then' "$dk"; then
  pass "helm upgrade rolls the pods when a Secret changed"
else
  fail "restart after a Secret change"
fi
steps_order="$(yq '[.jobs.deploy.steps[].name] | join("|")' "$dk")"
case "$steps_order" in
  *"Provision application Secrets|Run the migration Job|Helm upgrade"*) pass "Secrets are provisioned before the migration Job and the upgrade" ;;
  *) fail "order of the deploy steps: $steps_order" ;;
esac

sec_reset example-api-app example-api-migrate
sec_reject "a required value that is not set (missing repository secret)" "no value for: app.DB_PASSWORD" "$(printf 'migrate.DB_PASSWORD=x\napp.DB_PASSWORD=\n')"
sec_reject "a key that the values do not declare" "app.STRIPE_KEY is not declared in requiredSecrets" "app.STRIPE_KEY=x"
sec_reject "a Secret that the values do not declare" "other.DB_PASSWORD is not declared in requiredSecrets" "other.DB_PASSWORD=x"
sec_reject "a key declared only for stage (dev run)" "app.AWS_ACCESS_KEY_ID is not declared in requiredSecrets" "app.AWS_ACCESS_KEY_ID=x"
sec_reject "a line without '='" "every line must be <secret>.<KEY>=<value>" "app.DB_PASSWORD"
sec_reject "a line that does not name <secret>.<KEY>" "does not start with <secret>.<KEY>" "DB_PASSWORD=x"
sec_reject "a name with shell or JSON metacharacters" "does not start with <secret>.<KEY>" 'app.DB"PASSWORD=x'
sec_reject "the same key twice" "app.DB_PASSWORD is listed twice" "$(printf 'app.DB_PASSWORD=a\napp.DB_PASSWORD=b\n')"
sec_reject "nothing declared at all" "is not declared in requiredSecrets" "app.DB_PASSWORD=x" ""
sec_reject "the runner may not patch one of the Secrets" "may not patch Secret example-api-migrate" "$mapping" "$dev_declared" "patch:example-api-migrate"
sec_reject "the runner may not read back one of the Secrets" "may not get Secret example-api-app" "$mapping" "$dev_declared" "get:example-api-app"
if provision "app.DB_PASSWORD=super-secret-line" "$dev_declared" "patch:example-api-app" || ! grep -q 'super-secret-line' <(grep -v '^::add-mask::' "$WORK/sec.log"); then
  pass "error messages never repeat a value"
else
  fail "an error message contains a value"
fi
sec_reset example-api-app
sec_reject "a Secret object the platform has not created" "Secret example-api-migrate does not exist" "$(printf 'migrate.DB_PASSWORD=x\n')"
if [ "$(grep -cE 'kubectl [^|]*create -f -' <<<"$sec_step")" = "1" ] && [ "$(grep -c 'can-i create secrets' <<<"$sec_step")" = "1" ] \
   && ! grep -qE 'kubectl [^|]*(delete|replace|get secrets|get secret -|list)' <<<"$sec_step" && ! grep -q -- '--all-namespaces\|-A ' <<<"$sec_step"; then
  pass "the Secret step creates a Secret in one place only (pass-through), and never deletes, replaces or lists Secrets"
else
  fail "create / delete / list calls in the Secret step"
fi
for tpl in "${templates[@]}"; do
  if grep -qE 'secrets: *inherit' "$tpl"; then fail "$tpl uses secrets: inherit"; fi
done
pass "no template passes secrets wholesale (secrets: inherit)"

echo "== deploy-k8s.yml: environment bundle (env-bundle)"
bn_src=tests/bundle
bn_step="$(yq '.jobs.validate.steps[] | select(.id == "bundle") | .run' "$dk")"
# shellcheck disable=SC2016  # literal workflow text
if [ "$(grep -c 'secrets\.env-bundle' "$dk")" = "3" ] \
   && [ "$(yq '.jobs.validate.steps[0].env.ENV_BUNDLE_SUPPLIED' "$dk")" = '${{ secrets.env-bundle != '"''"' }}' ] \
   && [ "$(yq '[.jobs.validate.steps[] | select(.env.ENV_BUNDLE != null) | .id] | join(",")' "$dk")" = "bundle" ] \
   && [ "$(yq '[.jobs.deploy.steps[] | select(.env.ENV_BUNDLE != null) | .id] | join(",")' "$dk")" = "secrets" ]; then
  pass "the bundle reaches exactly two steps: the check (validate job) and the Secret provisioning (deploy job)"
else
  fail "where env-bundle is referenced"
fi
if grep -qE 'toJSON\(secrets\)|secrets: *inherit' "$dk" "${templates[@]}"; then
  fail "a workflow serializes the secrets context or inherits all secrets"
else
  pass "no workflow serializes the secrets context or passes secrets wholesale"
fi
if grep -qE 'GITHUB_STEP_SUMMARY|set -x|tee ' <<<"$bn_step"; then
  fail "the bundle check writes to the summary or traces commands"
else
  pass "the bundle check writes nothing to the summary and has no command trace"
fi
reject "env-bundle passed to a validation-only run" dev refs/heads/dev-k8s/feature-x push true "" "" deploy "" Akjet-dev/backend "" false true
reject "env-bundle passed to stage validation" stage refs/heads/stage-k8s/release push true "" "" deploy "" Akjet-dev/backend "" false true
reject "env-bundle together with app-secrets" "${rel[@]}" "" deploy "" Akjet-dev/backend "" true true
accept "env-bundle passed to the deploying run" "deploy=true" "${rel[@]}" "" deploy "" Akjet-dev/backend "" false true

bundle_check() {  # environment, bundle text, [directory with deploy/]
  : >"$WORK/bn_output"; rm -f "$WORK/bundle-config.json"
  ( cd "${3:-$bn_src}" && env -i PATH="$PATH" RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/bn_output" \
      ENVIRONMENT="$1" VALUES_DIR=deploy ENV_BUNDLE="$2" bash --noprofile --norc -c "$bn_step" ) </dev/null >"$WORK/bn.log" 2>&1
}
bn_plan() { sed -n 's/^plan=//p' "$WORK/bn_output"; }
bn_expect() {  # label, expected plan, expected config JSON, environment, bundle
  local label="$1" plan="$2" cfg="$3"; shift 3
  if bundle_check "$@" && [ "$(bn_plan)" = "$plan" ] && [ "$(jq -cS . "$WORK/bundle-config.json")" = "$cfg" ]; then pass "$label"
  else fail "$label: plan='$(bn_plan)' config='$(cat "$WORK/bundle-config.json" 2>/dev/null)'"; cat "$WORK/bn.log"; fi
}
bn_reject() {  # label, expected text, environment, bundle, [dir]
  local label="$1" text="$2"; shift 2
  if bundle_check "$@"; then fail "accepted: $label"
  elif grep -qF -- "$text" "$WORK/bn.log"; then pass "rejected: $label"
  else fail "rejected for another reason: $label"; cat "$WORK/bn.log"; fi
}
bn_json() { jq -cn "$@"; }   # builds test bundles; values never appear on a command line of the step under test

bn_expect "no bundle: nothing is planned, values files are used as they are" "" '{}' dev ""
# A multi-line value with quotes, a backslash, shell metacharacters and non-ASCII text.
# shellcheck disable=SC2016  # literal text with shell metacharacters, on purpose
cert="$(printf -- '-----BEGIN KEY-----\nline "two" $HOME `id` \\ end\nтретья строка: ключ ✓\n-----END KEY-----\n')"
pw_app='App-Pässwörd=1"; echo pwned'
pw_mig='Migrator-0nly/секрет'
# shellcheck disable=SC2016  # jq program
good_dev="$(bn_json --arg c "$cert" --arg a "$pw_app" --arg m "$pw_mig" '{DEV_APP_KEY: "base64:QUJDRA==", DEV_DB_PASSWORD: $a, DEV_DB_MIGRATOR_PASSWORD: $m, DEV_PARTNER_CERTIFICATE: $c, DEV_DB_HOST: "db.bundle.example.test", DEV_APP_URL: ""}')"
bn_expect "dev bundle: Secret keys are planned by name, configuration goes to the overrides step, empty values are ignored" \
  "app.APP_KEY=APP_KEY app.DB_PASSWORD=DB_PASSWORD app.PARTNER_CERTIFICATE=PARTNER_CERTIFICATE migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD" \
  '{"DEV_DB_HOST":"db.bundle.example.test"}' dev "$good_dev"
if ! grep -qF -e "$pw_app" -e "$pw_mig" -e 'третья строка' -e 'QUJDRA' "$WORK/bn.log" "$WORK/bn_output" "$WORK/bundle-config.json" \
   && ! grep -rqF -e "$pw_mig" -e 'третья строка' "$WORK"/bundle-*.json; then
  pass "the bundle check prints and stores no secret value (log, outputs, intermediate files)"
else
  fail "a secret value leaked from the bundle check"
fi
if grep -qF 'Secret keys from the bundle: app.APP_KEY, app.DB_PASSWORD, app.PARTNER_CERTIFICATE, migrate.DB_PASSWORD' "$WORK/bn.log" \
   && grep -qF 'Configuration overrides from the bundle: DB_HOST' "$WORK/bn.log" && grep -qE '^env-bundle: [0-9]+ bytes' "$WORK/bn.log"; then
  pass "the bundle check reports names and the size only"
else
  fail "report of the bundle check"; cat "$WORK/bn.log"
fi
to_env() { jq -c --arg from "DEV_" --arg to "$1" 'with_entries(.key |= ($to + ltrimstr($from)))' <<<"$good_dev"; }
bn_expect "stage: the same names resolve with the STAGE_ prefix" \
  "app.APP_KEY=APP_KEY app.DB_PASSWORD=DB_PASSWORD app.PARTNER_CERTIFICATE=PARTNER_CERTIFICATE migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD" \
  '{"STAGE_DB_HOST":"db.bundle.example.test"}' stage "$(to_env STAGE_)"
# shellcheck disable=SC2016  # jq program
bn_expect "a third environment resolves with its own prefix; Secrets declared only there are accepted" \
  "app.APP_KEY=APP_KEY app.DB_PASSWORD=DB_PASSWORD app.PARTNER_CERTIFICATE=PARTNER_CERTIFICATE migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD integrations.PARTNER_API_TOKEN=PARTNER_API_TOKEN" \
  '{"PROD_DB_HOST":"db.bundle.example.test","PROD_PARTNER_API_URL":"https://partner.example.test"}' prod \
  "$(to_env PROD_ | jq -c '. + {PROD_PARTNER_API_TOKEN: "t0ken", PROD_PARTNER_API_URL: "https://partner.example.test"}')"
bn_reject "dev: a Secret declared only for stage" "PARTNER_API_TOKEN is declared neither in requiredSecrets" dev "$(jq -c '. + {DEV_PARTNER_API_TOKEN: "x"}' <<<"$good_dev")"
bn_reject "dev run with the stage bundle (no cross-environment fallback)" "STAGE_DB_PASSWORD does not start with DEV_" dev "$(to_env STAGE_)"
if grep -qF 'DEV_DB_PASSWORD is required' "$WORK/bn.log" && ! grep -qF -e "$pw_app" -e "$pw_mig" "$WORK/bn.log"; then
  pass "  ... and the credentials of the other environment are neither used nor printed"
else
  fail "cross-environment bundle handling"; cat "$WORK/bn.log"
fi
bn_reject "one key of another environment inside the dev bundle" "STAGE_DB_HOST does not start with DEV_" dev "$(jq -c '. + {STAGE_DB_HOST: "db.other.example.test"}' <<<"$good_dev")"
bn_reject "a required Secret key is missing" "DEV_DB_PASSWORD is required (key of Secret app.DB_PASSWORD)" dev "$(jq -c 'del(.DEV_DB_PASSWORD)' <<<"$good_dev")"
bn_reject "a required Secret key is empty" "DEV_APP_KEY is required" dev "$(jq -c '.DEV_APP_KEY = ""' <<<"$good_dev")"
bn_reject "the migration password is missing (no fallback to the application password)" "DEV_DB_MIGRATOR_PASSWORD is required (key of Secret migrate.DB_PASSWORD)" dev "$(jq -c 'del(.DEV_DB_MIGRATOR_PASSWORD)' <<<"$good_dev")"
bn_expect "an optional Secret key may be absent" "app.APP_KEY=APP_KEY app.DB_PASSWORD=DB_PASSWORD migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD" '{"DEV_DB_HOST":"db.bundle.example.test"}' dev "$(jq -c 'del(.DEV_PARTNER_CERTIFICATE)' <<<"$good_dev")"
bn_reject "not JSON" "env-bundle is not a JSON object" dev 'DEV_DB_PASSWORD=super-secret-not-json'
if grep -q 'super-secret-not-json' "$WORK/bn.log"; then fail "invalid JSON is echoed"; else pass "  ... and the unparsable content is not echoed"; fi
bn_reject "a JSON array instead of an object" "env-bundle is not a JSON object" dev '["DEV_DB_PASSWORD"]'
bn_reject "a number instead of a string" "DEV_DB_PORT: the value must be a JSON string, not number" dev "$(jq -c '. + {DEV_DB_PORT: 5432}' <<<"$good_dev")"
bn_reject "a nested object instead of a string" "DEV_DB_PASSWORD: the value must be a JSON string, not object" dev "$(jq -c '.DEV_DB_PASSWORD = {a: "b"}' <<<"$good_dev")"
bn_reject "null instead of a string" "DEV_APP_KEY: the value must be a JSON string, not null" dev "$(jq -c '.DEV_APP_KEY = null' <<<"$good_dev")"
bn_reject "a key with an invalid name" "has an invalid name" dev "$(jq -c '. + {"DEV_db-host; rm -rf": "x"}' <<<"$good_dev")"
if grep -q 'rm -rf' "$WORK/bn.log"; then fail "an invalid key is echoed"; else pass "  ... and the invalid key is not echoed"; fi
bn_reject "a key without the environment prefix" "a key does not start with DEV_" dev "$(jq -c '. + {"db_password": "x"}' <<<"$good_dev")"
bn_reject "configuration that the service did not make overridable" "LOG_CHANNEL is set in the values files and is not listed under overrides" dev "$(jq -c '. + {DEV_LOG_CHANNEL: "stack"}' <<<"$good_dev")"
bn_reject "a name nobody declared" "WHATEVER is declared neither in requiredSecrets" dev "$(jq -c '. + {DEV_WHATEVER: "x"}' <<<"$good_dev")"
bn_reject "a name locked for dev (safety switch)" "FEATURE_WRITES_ENABLED is locked for dev" dev "$(jq -c '. + {DEV_FEATURE_WRITES_ENABLED: "true"}' <<<"$good_dev")"
bn_reject "an endpoint locked for dev" "PARTNER_API_URL is locked for dev" dev "$(jq -c '. + {DEV_PARTNER_API_URL: "https://partner.example.test"}' <<<"$good_dev")"
bn_expect "the same switch is not locked for stage" "app.APP_KEY=APP_KEY app.DB_PASSWORD=DB_PASSWORD app.PARTNER_CERTIFICATE=PARTNER_CERTIFICATE migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD" \
  '{"STAGE_DB_HOST":"db.bundle.example.test","STAGE_FEATURE_WRITES_ENABLED":"true"}' stage "$(to_env STAGE_ | jq -c '. + {STAGE_FEATURE_WRITES_ENABLED: "true"}')"
bn_noalias="$WORK/bn-noalias"; rm -rf "$bn_noalias"; mkdir -p "$bn_noalias"; cp -R "$bn_src/deploy" "$bn_noalias/"; yq -i 'del(.secrets.aliases)' "$bn_noalias/deploy/overrides.yaml"
bn_reject "one bundle name for two Secret keys (application and migration password) without an alias" "DB_PASSWORD is the bundle name of more than one Secret key (app.DB_PASSWORD, migrate.DB_PASSWORD)" dev "$good_dev" "$bn_noalias"

# precedence: values file < repository variable < bundle; both are validated by the overrides step
bn_overrides() {  # environment, repository variables JSON -> overrides JSON (after bundle_check)
  : >"$WORK/ov_output"
  ( cd "$bn_src" && env -i PATH="$PATH" RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/ov_output" GITHUB_STEP_SUMMARY="$WORK/ov_summary" \
      ENVIRONMENT="$1" VALUES_DIR=deploy REPOSITORY_VARIABLES="$2" bash --noprofile --norc -c "$ov_step" ) </dev/null >"$WORK/ov.log" 2>&1 && ov_json
}
bundle_check dev "$good_dev"
if [ "$(bn_overrides dev '{"DEV_DB_HOST":"db.variable.example.test","DEV_DB_PORT":"6000"}')" = '{"config":{"DB_HOST":"db.bundle.example.test","DB_PORT":"6000"}}' ]; then
  pass "precedence: the bundle wins over a repository variable; a variable still applies where the bundle is silent"
else
  fail "precedence bundle / variable: $(ov_json)"; cat "$WORK/ov.log"
fi
bn_render() { "$HELM" template example-api "$CHART" --namespace dev-example-api -f "$bn_src/deploy/values.yaml" -f "$bn_src/deploy/values-$1.yaml" -f "$WORK/overrides.json" "${@:2}"; }
if [ "$(bn_render dev | yq 'select(.kind == "ConfigMap") | .data.DB_HOST + " " + .data.DB_PORT + " " + .data.DB_USERNAME')" = "db.bundle.example.test 6000 example_dev_app" ]; then
  pass "precedence: the rendered ConfigMap carries bundle > variable > values file"
else
  fail "rendered precedence"
fi
bundle_check dev "$(jq -c 'del(.DEV_DB_HOST)' <<<"$good_dev")"
if [ "$(bn_overrides dev '{}')" = '{}' ] && [ "$(bn_render dev | yq 'select(.kind == "ConfigMap") | .data.DB_HOST')" = "db.default.example.test" ]; then
  pass "fallback: without an override the value of the values file is used"
else
  fail "fallback to the values file"
fi
bundle_check dev "$(jq -c '.DEV_DB_PORT = "not-a-number"' <<<"$good_dev")"
if bn_overrides dev '{}' >/dev/null; then fail "an invalid type from the bundle was accepted"
elif grep -qF 'variable DEV_DB_PORT: not an integer' "$WORK/ov.log"; then pass "configuration from the bundle is type-checked like a repository variable"
else fail "type check of bundle configuration"; cat "$WORK/ov.log"; fi
rm -f "$WORK/bundle-config.json"
if bn_overrides dev '{"DEV_FEATURE_WRITES_ENABLED":"true"}' >/dev/null; then fail "a locked name was accepted from a repository variable"
elif grep -qF 'FEATURE_WRITES_ENABLED is locked for dev' "$WORK/ov.log"; then pass "a locked name is refused from a repository variable too"
else fail "locked name from a variable"; cat "$WORK/ov.log"; fi
if [ "$(bn_overrides stage '{"STAGE_FEATURE_WRITES_ENABLED":"true"}')" = '{"config":{"FEATURE_WRITES_ENABLED":"true"}}' ]; then
  pass "  ... while the environment that does not lock it accepts it"
else
  fail "locked list is per environment"; cat "$WORK/ov.log"
fi

# deploy side: only names cross between the jobs; values go from the bundle straight into kubectl's stdin
bundle_check dev "$good_dev"; bn_good_plan="$(bn_plan)"
bn_declared="app.APP_KEY app.DB_PASSWORD app.PARTNER_CERTIFICATE migrate.DB_PASSWORD"
provision_bundle() {  # bundle, plan, [declared], [denied], [app-secrets]
  : >"$WORK/sec_output"
  env -i PATH="$fakebin:$PATH" GITHUB_OUTPUT="$WORK/sec_output" RUNNER_TEMP="$WORK" FAKE_STATE="$sec_state" FAKE_DENY="${4:-}" \
    NAMESPACE=dev-example-api RELEASE=example-api VALUES_DIR=deploy ENVIRONMENT=dev \
    ENV_BUNDLE="$1" PLAN="$2" DECLARED="${3-$bn_declared}" APP_SECRETS="${5:-}" bash --noprofile --norc -c "$sec_step" </dev/null >"$WORK/sec.log" 2>&1
}
bnp_reject() {  # label, expected text, provision_bundle args...
  local label="$1" text="$2"; shift 2
  if provision_bundle "$@"; then fail "accepted: $label"
  elif ! grep -qF -- "$text" "$WORK/sec.log"; then fail "rejected for another reason: $label"; grep -v '^::add-mask::' "$WORK/sec.log"
  elif grep -q ' apply ' "$sec_state/calls.log"; then fail "$label: a Secret was written before the failure"
  else pass "rejected, nothing written: $label"; fi
}
sec_reset example-api-app example-api-migrate
if provision_bundle "$good_dev" "$bn_good_plan" && [ "$(cat "$WORK/sec_output")" = "changed=true" ] \
   && [ "$(sec_data example-api-app DB_PASSWORD)" = "$pw_app" ] && [ "$(sec_data example-api-app APP_KEY)" = "base64:QUJDRA==" ] \
   && [ "$(jq -r '.PARTNER_CERTIFICATE | @base64d' "$sec_state/example-api-app.json"; echo x)" = "$(printf '%s\nx' "$cert")" ]; then
  pass "bundle values reach the Secret byte for byte: multi-line, quotes, backslash, shell metacharacters, non-ASCII"
else
  fail "provisioning from the bundle"; grep -v '^::add-mask::' "$WORK/sec.log"; cat "$sec_state/calls.log"
fi
if [ "$(sec_data example-api-migrate DB_PASSWORD)" = "$pw_mig" ] && [ "$(jq -c 'keys' "$sec_state/example-api-migrate.json")" = '["DB_PASSWORD"]' ] \
   && [ "$(sec_data example-api-app DB_PASSWORD)" != "$pw_mig" ]; then
  pass "migration credentials: <ENV>_DB_MIGRATOR_PASSWORD becomes DB_PASSWORD of the migrate Secret; the application password is not mixed in"
else
  fail "migration credentials from the bundle"
fi
if [ "$(jq -c 'keys' "$sec_state/example-api-app.json")" = '["APP_KEY","DB_PASSWORD","PARTNER_CERTIFICATE"]' ]; then
  pass "the applied manifest lists exactly the planned keys (server-side apply leaves every other key of the Secret alone)"
else
  fail "keys of the applied manifest: $(jq -c 'keys' "$sec_state/example-api-app.json")"
fi
if ! grep -v '^::add-mask::' "$WORK/sec.log" | grep -qF -e "$pw_app" -e "$pw_mig" -e 'третья строка' -e 'QUJDRA' \
   && ! grep -qF -e "$pw_app" -e "$pw_mig" -e 'третья строка' "$WORK/sec_output" "$sec_state/calls.log" \
   && ! grep -qF "$(printf '%s' "$pw_mig" | base64 | tr -d '\n')" "$WORK/sec.log" "$sec_state/calls.log" \
   && grep -qF -- "::add-mask::$pw_mig" "$WORK/sec.log" && grep -qF '::add-mask::третья строка: ключ ✓' "$WORK/sec.log" \
   && [ ! -e "$WORK/app-secrets-changed" ] && ! grep -qsF -e "$pw_mig" -e "$pw_app" "$WORK"/*.json; then
  pass "values appear only in masking commands (every line of a multi-line value is masked); not in logs, outputs, command lines or files"
else
  fail "a bundle value leaked on the deploy side"; grep -v '^::add-mask::' "$WORK/sec.log"
fi
if provision_bundle "$good_dev" "$bn_good_plan" && [ "$(cat "$WORK/sec_output")" = "changed=false" ]; then
  pass "an unchanged bundle modifies nothing and requests no restart"
else
  fail "second run with the same bundle"; cat "$WORK/sec_output"
fi
if provision_bundle "$(jq -c '.DEV_DB_PASSWORD = "rotated"' <<<"$good_dev")" "$bn_good_plan" && [ "$(cat "$WORK/sec_output")" = "changed=true" ] \
   && [ "$(sec_data example-api-app DB_PASSWORD)" = "rotated" ] && [ "$(sec_data example-api-migrate DB_PASSWORD)" = "$pw_mig" ]; then
  pass "a rotated value updates its Secret and requests a restart of the pods"
else
  fail "rotation through the bundle"
fi
: >"$sec_state/calls.log"
if provision_bundle '{"DEV_DB_HOST":"db.bundle.example.test"}' "" && [ "$(cat "$WORK/sec_output")" = "changed=false" ] && [ ! -s "$sec_state/calls.log" ]; then
  pass "a bundle with configuration only leaves Kubernetes Secrets alone"
else
  fail "bundle without Secret keys"
fi
sec_reset example-api-app example-api-migrate
bnp_reject "the bundle lost a planned key between the jobs" "does not contain every key planned" "$(jq -c 'del(.DEV_DB_MIGRATOR_PASSWORD)' <<<"$good_dev")" "$bn_good_plan"
bnp_reject "a planned key that the values do not declare" "app.STRIPE_KEY is not declared in requiredSecrets" "$good_dev" "$bn_good_plan app.STRIPE_KEY=DB_PASSWORD"
# shellcheck disable=SC2016  # a literal attempt at command injection
bnp_reject "a malformed plan" "plan of the validate job is malformed" "$good_dev" 'app.DB_PASSWORD=$(id)'
bnp_reject "the runner may not patch one of the Secrets (checked before the first write)" "may not patch Secret example-api-migrate" "$good_dev" "$bn_good_plan" "$bn_declared" "patch:example-api-migrate"
bnp_reject "env-bundle and app-secrets in one run" "pass either env-bundle or app-secrets" "$good_dev" "$bn_good_plan" "$bn_declared" "" "app.DB_PASSWORD=x"
sec_reset example-api-app
bnp_reject "a Secret object the platform has not created" "Secret example-api-migrate does not exist" "$good_dev" "migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD"

# what Helm stores: release values and rendered objects never contain a Secret value
bundle_check dev "$good_dev"; bn_overrides dev '{}' >/dev/null
bn_render dev --set migration.render=true --set-string migration.runId=t1 >"$WORK/bn-rendered.yaml"
if ! grep -qF -e "$pw_app" -e "$pw_mig" -e 'QUJDRA' -e 'BEGIN KEY' "$WORK/overrides.json" "$WORK/bn-rendered.yaml" \
   && [ "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$WORK/bn-rendered.yaml")" = "" ] \
   && ! yq -N -o=json 'select(.kind == "ConfigMap") | .data | keys' "$WORK/bn-rendered.yaml" | grep -qiE 'PASSWORD|APP_KEY|CERTIFICATE'; then
  pass "no Secret value in what Helm stores: the values passed to helm, the ConfigMap and every rendered object"
else
  fail "a Secret value reached the Helm input or a rendered object"
fi
bn_objects="$(yq ea -o=json '[.]' "$WORK/bn-rendered.yaml")"
if [ "$(jq -c '.[] | select(.kind == "Job") | .spec.template.spec.containers[0] | [(.env[] | select(.name == "DB_USERNAME") | .value), ([.envFrom[].secretRef.name] | join(","))]' <<<"$bn_objects")" = '["example_migrator","example-api-app,example-api-migrate"]' ] \
   && [ "$(yq -N 'select(.kind == "ConfigMap") | .data.DB_USERNAME' "$WORK/bn-rendered.yaml")" = "example_dev_app" ]; then
  pass "migrations run as the migration role with the migrate Secret last (its DB_PASSWORD wins); the application keeps its own role"
else
  fail "migration role / Secret order"
fi
if [ "$(jq -c '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0] | [((.env // []) | length), ([.envFrom[] | keys[0]] | join(","))]' <<<"$bn_objects")" = '[0,"configMapRef,secretRef"]' ] \
   && [ "$(jq -c '.[] | select(.kind == "Job") | .spec.template.spec.containers[0].env | map(.name) | (length == (unique | length))' <<<"$bn_objects")" = "true" ]; then
  pass "no variable is declared twice: configuration comes from the ConfigMap, Secret keys from the Secret, nothing in env"
else
  fail "duplicate environment declarations"
fi

# operator tool = the same step
if ( cd "$bn_src" && TMPDIR="$WORK" ../../scripts/env-bundle.sh template stage ) >"$WORK/tpl.json" 2>"$WORK/tpl.log" \
   && [ "$(jq -c '[keys[] | select(startswith("STAGE_") | not)] | length' "$WORK/tpl.json")" = "0" ] \
   && [ "$(jq -c '[.[] | select(. != "")] | length' "$WORK/tpl.json")" = "0" ] \
   && [ "$(jq -r 'keys_unsorted[0:3] | join(",")' "$WORK/tpl.json")" = "STAGE_APP_KEY,STAGE_DB_PASSWORD,STAGE_DB_MIGRATOR_PASSWORD" ] \
   && jq -e 'has("STAGE_PARTNER_API_TOKEN") and has("STAGE_FEATURE_WRITES_ENABLED") and has("STAGE_DB_HOST")' "$WORK/tpl.json" >/dev/null; then
  pass "scripts/env-bundle.sh template: every key of the environment, required first, all values empty"
else
  fail "env-bundle.sh template"; cat "$WORK/tpl.log" "$WORK/tpl.json"
fi
if ( cd "$bn_src" && TMPDIR="$WORK" ../../scripts/env-bundle.sh template dev ) | jq -e 'has("DEV_FEATURE_WRITES_ENABLED") or has("DEV_PARTNER_API_TOKEN") | not' >/dev/null; then
  pass "  ... locked names and Secrets of other environments are left out of the dev template"
else
  fail "dev template contains locked or undeclared names"
fi
printf '%s' "$good_dev" >"$WORK/operator-bundle.json"
if ( cd "$bn_src" && TMPDIR="$WORK" ../../scripts/env-bundle.sh check dev "$WORK/operator-bundle.json" ) >"$WORK/op.log" 2>&1 \
   && grep -qF 'Secret keys from the bundle' "$WORK/op.log" && ! grep -qF -e "$pw_app" -e "$pw_mig" "$WORK/op.log"; then
  pass "scripts/env-bundle.sh check: accepts a valid bundle and prints names only"
else
  fail "env-bundle.sh check (valid)"; cat "$WORK/op.log"
fi
( cd "$bn_src" && TMPDIR="$WORK" ../../scripts/env-bundle.sh template dev ) >"$WORK/operator-empty.json"
if ( cd "$bn_src" && TMPDIR="$WORK" ../../scripts/env-bundle.sh check dev "$WORK/operator-empty.json" ) >"$WORK/op.log" 2>&1; then
  fail "env-bundle.sh check accepted an unfilled template"
elif [ "$(grep -c '^ERROR: env-bundle: .* is required' "$WORK/op.log")" = "3" ]; then
  pass "scripts/env-bundle.sh check: an unfilled template is refused with the list of missing names"
else
  fail "env-bundle.sh check (missing)"; cat "$WORK/op.log"
fi

echo "== deploy-k8s.yml: pass-through bundle (input env-bundle-secret)"
if [ "$(yq '.on.workflow_call.inputs."env-bundle-secret" | .type + "/" + (.required // false | tostring) + "/" + .default' "$dk")" = "string/false/" ]; then
  pass "env-bundle-secret is an optional string input, empty by default (declared mode stays the default)"
else
  fail "env-bundle-secret input"
fi
pt_check() {  # environment, bundle, [secret=app], [dir]
  : >"$WORK/bn_output"; rm -f "$WORK/bundle-config.json"
  ( cd "${4:-$bn_src}" && env -i PATH="$PATH" RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/bn_output" \
      ENVIRONMENT="$1" VALUES_DIR=deploy ENV_BUNDLE="$2" BUNDLE_SECRET="${3-app}" bash --noprofile --norc -c "$bn_step" ) </dev/null >"$WORK/bn.log" 2>&1
}
pt_out() { sed -n "s/^$1=//p" "$WORK/bn_output"; }
pt_reject() {  # label, expected text, pt_check args...
  local label="$1" text="$2"; shift 2
  if pt_check "$@"; then fail "accepted: $label"
  elif grep -qF -- "$text" "$WORK/bn.log"; then pass "rejected: $label"
  else fail "rejected for another reason: $label"; cat "$WORK/bn.log"; fi
}
# shellcheck disable=SC2016  # a literal value with shell metacharacters, on purpose
pt_secret='S3cr3t "quoted" $HOME \ end'
# shellcheck disable=SC2016  # jq program
pt_bundle="$(jq -cn --arg s "$pt_secret" --arg c "$cert" '{DEV_REDIS_HOST: "127.0.0.1", DEV_DB_HOST: "127.0.0.1:5432 not a host name", DEV_DB_USERNAME: "runtime_role",
  DEV_NEVER_DECLARED_ANYWHERE: $s, DEV_FEATURE_WRITES_ENABLED: "maybe", DEV_APP_URL: "not a url", DEV_PARTNER_CERTIFICATE: $c, DEV_DB_PASSWORD: "app-pw",
  DEV_DB_MIGRATOR_PASSWORD: "mig-pw", DEV_PORT_AS_NUMBER: 6379, DEV_FLAG_AS_BOOLEAN: false, DEV_lowerCase_name: "x", DEV_EMPTY_IS_ABSENT: ""}')"
if pt_check dev "$pt_bundle" \
   && [ "$(pt_out plan)" = "app.REDIS_HOST=REDIS_HOST app.DB_HOST=DB_HOST app.DB_USERNAME=DB_USERNAME app.NEVER_DECLARED_ANYWHERE=NEVER_DECLARED_ANYWHERE app.FEATURE_WRITES_ENABLED=FEATURE_WRITES_ENABLED app.APP_URL=APP_URL app.PARTNER_CERTIFICATE=PARTNER_CERTIFICATE app.DB_PASSWORD=DB_PASSWORD migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD app.PORT_AS_NUMBER=PORT_AS_NUMBER app.FLAG_AS_BOOLEAN=FLAG_AS_BOOLEAN app.lowerCase_name=lowerCase_name" ] \
   && [ "$(jq -c . "$WORK/bundle-config.json")" = "{}" ]; then
  pass "pass-through: every <ENV>_<NAME> becomes key NAME of the one Secret - undeclared names, an address as REDIS_HOST, values that are no host / URL / boolean, numbers, booleans; nothing goes to config"
else
  fail "pass-through plan: $(pt_out plan)"; cat "$WORK/bn.log"
fi
if [ "$(pt_out shadowed)" = "DB_HOST FEATURE_WRITES_ENABLED" ]; then
  pass "pass-through: names that the values files also set are reported for the migration Job; names under migration.config (DB_USERNAME) are not"
else
  fail "shadowed names: '$(pt_out shadowed)'"
fi
if ! grep -qF -e "$pt_secret" -e 'app-pw' -e 'mig-pw' -e 'третья строка' -e 'not a url' "$WORK/bn.log" "$WORK/bn_output"; then
  pass "pass-through: the check prints names only"
else
  fail "a value leaked from the pass-through check"
fi
case " $(pt_out plan) " in
  *" migrate.DB_PASSWORD=DB_MIGRATOR_PASSWORD "*)
    case " $(pt_out plan) " in *"app.DB_MIGRATOR_PASSWORD"*) fail "the migration password is also planned for the application Secret" ;; *) pass "pass-through: the aliased migration password goes only to the migrate Secret" ;; esac ;;
  *) fail "migration password alias in pass-through mode" ;;
esac
pt_reject "malformed JSON (before any Kubernetes access)" "env-bundle is not a JSON object" dev '{"DEV_REDIS_HOST": "127.0.0.1"'
pt_reject "a JSON array" "env-bundle is not a JSON object" dev '[1]'
pt_reject "a nested object as a value" "DEV_X: the value must be a string, a number or a boolean, not object" dev '{"DEV_X": {"a": 1}}'
pt_reject "null as a value" "DEV_X: the value must be a string, a number or a boolean, not null" dev '{"DEV_X": null}'
pt_reject "a name that cannot be an environment variable" "is not a valid environment variable name" dev '{"DEV_bad-name": "x"}'
pt_reject "a key of another environment" "STAGE_REDIS_HOST does not start with DEV_" dev '{"STAGE_REDIS_HOST": "127.0.0.1"}'
pt_reject "a Secret that the values files do not declare" "nosuch is not a Secret declared in requiredSecrets" dev '{"DEV_X": "1"}' nosuch
pt_reject "an invalid Secret name" "env-bundle-secret must be the name of a Secret" dev '{"DEV_X": "1"}' 'app;id'
if pt_check dev '{"DEV_ONLY": "x"}' && [ "$(pt_out plan)" = "app.ONLY=ONLY" ]; then
  pass "pass-through: nothing is required - a bundle with one variable is accepted"
else
  fail "pass-through with a single key"; cat "$WORK/bn.log"
fi
# without the input the SAME bundle is still judged by the declared mode (other services are unaffected)
bn_reject "the same bundle without env-bundle-secret (declared mode unchanged)" "NEVER_DECLARED_ANYWHERE is declared neither in requiredSecrets" dev "$pt_bundle"

# deploy side: the Secret is created on the first deployment and merged into afterwards
pt_check dev "$pt_bundle"; pt_plan="$(pt_out plan)"; pt_shadowed="$(pt_out shadowed)"
pt_provision() {  # bundle, plan, [secret=app], [declared], [denied]; FAKE_GET / FAKE_CREATE / FAKE_PATCH from the environment
  : >"$WORK/sec_output"
  env -i PATH="$fakebin:$PATH" GITHUB_OUTPUT="$WORK/sec_output" RUNNER_TEMP="$WORK" FAKE_STATE="$sec_state" FAKE_DENY="${5:-}" \
    FAKE_GET="${FAKE_GET:-}" FAKE_CREATE="${FAKE_CREATE:-}" FAKE_PATCH="${FAKE_PATCH:-}" \
    NAMESPACE=dev-example-api RELEASE=example-api VALUES_DIR=deploy ENVIRONMENT=dev APP_SECRETS="" \
    ENV_BUNDLE="$1" PLAN="$2" BUNDLE_SECRET="${3-app}" DECLARED="${4-$bn_declared}" bash --noprofile --norc -c "$sec_step" </dev/null >"$WORK/sec.log" 2>&1
}
pt_no_leak() { ! grep -v '^::add-mask::' "$WORK/sec.log" | grep -qF -e "$pt_secret" -e 'app-pw' -e 'mig-pw' -e 'третья строка' -e 'not a host name' \
                 && ! grep -qF -e "$pt_secret" -e 'app-pw' -e 'mig-pw' "$WORK/sec_output" "$sec_state/calls.log"; }
pt_writes() { grep -cE ' (create -f -|patch secret |apply )' "$sec_state/calls.log" || true; }
# one Secret only: the plan of a service without aliases (what backend sends)
pt_single="$(tr ' ' '\n' <<<"$pt_plan" | grep -v '^migrate\.' | tr '\n' ' ' | sed 's/ $//')"
pt_keys='["APP_URL","DB_HOST","DB_PASSWORD","DB_USERNAME","FEATURE_WRITES_ENABLED","FLAG_AS_BOOLEAN","NEVER_DECLARED_ANYWHERE","PARTNER_CERTIFICATE","PORT_AS_NUMBER","REDIS_HOST","lowerCase_name"]'

sec_reset   # first deployment: the namespace holds no application Secret at all
if pt_provision "$pt_bundle" "$pt_single" && [ "$(cat "$WORK/sec_output")" = "changed=true" ] \
   && [ "$(jq -c 'keys' "$sec_state/example-api-app.json")" = "$pt_keys" ] && [ "$(wc -l <"$sec_state/example-api-app.created" | tr -d ' ')" = "1" ] \
   && grep -qF 'Secret example-api-app: created with 11 key(s)' "$WORK/sec.log" && ! grep -q ' patch secret \| apply ' "$sec_state/calls.log"; then
  pass "first deployment: the missing Secret is created by ONE request that carries the complete payload (no empty Secret first, no patch)"
else
  fail "creation of the missing Secret"; grep -v '^::add-mask::' "$WORK/sec.log"; cat "$sec_state/calls.log"
fi
if [ "$(sec_data example-api-app REDIS_HOST)" = "127.0.0.1" ] && [ "$(sec_data example-api-app NEVER_DECLARED_ANYWHERE)" = "$pt_secret" ] \
   && [ "$(sec_data example-api-app DB_HOST)" = "127.0.0.1:5432 not a host name" ] && [ "$(sec_data example-api-app PORT_AS_NUMBER)" = "6379" ] \
   && [ "$(sec_data example-api-app FLAG_AS_BOOLEAN)" = "false" ] && [ "$(sec_data example-api-app DB_USERNAME)" = "runtime_role" ] \
   && [ "$(sec_data example-api-app DB_PASSWORD)" = "app-pw" ] \
   && [ "$(jq -r '.PARTNER_CERTIFICATE | @base64d' "$sec_state/example-api-app.json"; echo x)" = "$(printf '%s\nx' "$cert")" ] \
   && [ "$(jq -r 'has("EMPTY_IS_ABSENT")' "$sec_state/example-api-app.json")" = "false" ]; then
  pass "every <ENV>_<NAME> entry is in the created Secret as NAME, value unchanged (multi-line, quotes, non-ASCII, numbers, booleans); an empty value is not written"
else
  fail "content of the created Secret"
fi
if [ ! -e "$sec_state/example-api-migrate.rv" ] && ! grep -q 'migrate' "$sec_state/calls.log"; then
  pass "a service without aliases writes exactly one Secret: no migrate Secret is created, read or referenced"
else
  fail "a second Secret was touched"; cat "$sec_state/calls.log"
fi
if pt_no_leak; then pass "creation: no value in the log, the outputs or a command line"; else fail "a value leaked while creating the Secret"; grep -v '^::add-mask::' "$WORK/sec.log"; fi
: >"$sec_state/calls.log"
if pt_provision "$pt_bundle" "$pt_single" && [ "$(cat "$WORK/sec_output")" = "changed=false" ] && ! grep -q ' create -f -' "$sec_state/calls.log" \
   && [ "$(wc -l <"$sec_state/example-api-app.created" | tr -d ' ')" = "1" ] && grep -qF 'Secret example-api-app: unchanged' "$WORK/sec.log"; then
  pass "repeated deployment with the same bundle: the Secret is neither recreated nor modified, and no restart is requested"
else
  fail "idempotent repeated deployment"; cat "$WORK/sec_output"; grep -v '^::add-mask::' "$WORK/sec.log"
fi
# an existing Secret with keys of other origin; the new bundle no longer carries REDIS_HOST
jq -c '. + {"WRITTEN_BY_SOMEONE_ELSE": "a2VlcA=="}' "$sec_state/example-api-app.json" >"$sec_state/tmp.json" && mv "$sec_state/tmp.json" "$sec_state/example-api-app.json"
pt_smaller="$(jq -c 'del(.DEV_REDIS_HOST) | .DEV_DB_PASSWORD = "rotated-pw" | .DEV_ADDED_LATER = "new"' <<<"$pt_bundle")"
pt_check dev "$pt_smaller"; pt_smaller_plan="$(tr ' ' '\n' <<<"$(pt_out plan)" | grep -v '^migrate\.' | tr '\n' ' ' | sed 's/ $//')"
if pt_provision "$pt_smaller" "$pt_smaller_plan" && [ "$(cat "$WORK/sec_output")" = "changed=true" ] \
   && [ "$(sec_data example-api-app DB_PASSWORD)" = "rotated-pw" ] && [ "$(sec_data example-api-app ADDED_LATER)" = "new" ] \
   && grep -qF 'Secret example-api-app: updated' "$WORK/sec.log" && ! grep -q ' create -f -' <(tail -n +1 "$sec_state/calls.log" | tail -8); then
  pass "later deployment: the existing Secret is updated in place - a rotated value and a new variable arrive, and a restart is requested"
else
  fail "update of the existing Secret"; grep -v '^::add-mask::' "$WORK/sec.log"
fi
if [ "$(sec_data example-api-app WRITTEN_BY_SOMEONE_ELSE)" = "keep" ] && [ "$(sec_data example-api-app REDIS_HOST)" = "127.0.0.1" ]; then
  pass "keys that are not in the bundle are preserved: a key of other origin stays, and a key dropped from the bundle is not removed"
else
  fail "unrelated keys were changed or removed: $(jq -c 'keys' "$sec_state/example-api-app.json")"
fi
# with an alias (services that keep a separate migration Secret): both Secrets are created, the passwords stay apart
sec_reset
if pt_provision "$pt_bundle" "$pt_plan" && [ "$(sec_data example-api-migrate DB_PASSWORD)" = "mig-pw" ] && [ "$(jq -c 'keys' "$sec_state/example-api-migrate.json")" = '["DB_PASSWORD"]' ] \
   && [ "$(sec_data example-api-app DB_PASSWORD)" = "app-pw" ] && [ "$(jq -r 'has("DB_MIGRATOR_PASSWORD")' "$sec_state/example-api-app.json")" = "false" ]; then
  pass "an aliased entry still goes to its own Secret only (services with a separate migration password are unaffected)"
else
  fail "aliased entry in pass-through mode"; grep -v '^::add-mask::' "$WORK/sec.log"
fi

pt_reject_deploy() {  # label, text, pt_provision args
  local label="$1" text="$2"; shift 2
  if pt_provision "$@"; then fail "accepted: $label"
  elif ! grep -qF -- "$text" "$WORK/sec.log"; then fail "rejected for another reason: $label"; grep -v '^::add-mask::' "$WORK/sec.log"
  elif [ "$(pt_writes)" != "0" ]; then fail "$label: the cluster was modified before the failure"; cat "$sec_state/calls.log"
  elif ! pt_no_leak; then fail "$label: a value appears in the output"
  else pass "rejected, nothing written: $label"; fi
}
sec_reset
pt_reject_deploy "the Secret is missing and the runner may not create Secrets" "does not exist in dev-example-api and the runner may not create it: its Role needs create on Secrets" "$pt_bundle" "$pt_single" app "$bn_declared" "create:secrets"
pt_reject_deploy "the runner may not patch the Secret" "may not patch Secret example-api-app in dev-example-api: its Role needs patch on Secrets" "$pt_bundle" "$pt_single" app "$bn_declared" "patch:example-api-app"
pt_reject_deploy "the runner may not get the Secret" "may not get Secret example-api-app in dev-example-api: its Role needs get on Secrets" "$pt_bundle" "$pt_single" app "$bn_declared" "get:example-api-app"
sec_reset
FAKE_GET=forbidden pt_reject_deploy "reading the Secret is Forbidden (not treated as a missing Secret)" "may not read Secret example-api-app in dev-example-api (Forbidden)" "$pt_bundle" "$pt_single"
if grep -q 'does not exist' "$WORK/sec.log" || grep -q ' create ' "$sec_state/calls.log"; then fail "Forbidden was mistaken for NotFound"; else pass "  ... no creation is attempted after Forbidden"; fi
FAKE_GET=unreachable pt_reject_deploy "the API does not answer (not treated as a missing Secret)" "the Kubernetes API did not answer the request (not a missing Secret" "$pt_bundle" "$pt_single"
pt_reject_deploy "an undeclared key without pass-through (the input is what opens the Secret)" "app.REDIS_HOST is not declared in requiredSecrets" "$pt_bundle" "$pt_single" ""
pt_reject_deploy "a planned key of another Secret than the pass-through one" "other.X is not declared in requiredSecrets" "$pt_bundle" "other.X=REDIS_HOST"
pt_reject_deploy "a pass-through Secret that the values do not declare" "nosuch.X is not declared in requiredSecrets" "$pt_bundle" "nosuch.X=REDIS_HOST" nosuch
pt_reject_deploy "a bundle that is not valid JSON on the deploy side" "does not contain every key planned" '{"DEV_REDIS_HOST": "127.0.0.1"' "$pt_single"
sec_reset
if FAKE_CREATE=forbidden pt_provision "$pt_bundle" "$pt_single"; then fail "a Forbidden create was accepted"
elif grep -qF 'may not create Secret example-api-app in dev-example-api (Forbidden)' "$WORK/sec.log" && [ ! -e "$sec_state/example-api-app.rv" ] && pt_no_leak; then
  pass "create answered Forbidden by the API: reported as a missing create permission, nothing exists afterwards, no value printed"
else fail "Forbidden on create"; grep -v '^::add-mask::' "$WORK/sec.log"; fi
sec_reset example-api-app
if FAKE_PATCH=forbidden pt_provision "$pt_bundle" "$pt_single"; then fail "a Forbidden patch was accepted"
elif grep -qF 'may not patch Secret example-api-app in dev-example-api (Forbidden)' "$WORK/sec.log" && pt_no_leak; then
  pass "patch answered Forbidden by the API: reported as a missing patch permission, no value printed"
else fail "Forbidden on patch"; grep -v '^::add-mask::' "$WORK/sec.log"; fi
sec_reset
if FAKE_CREATE=race pt_provision "$pt_bundle" "$pt_single" && [ "$(cat "$WORK/sec_output")" = "changed=true" ] \
   && [ "$(sec_data example-api-app REDIS_HOST)" = "127.0.0.1" ] && [ "$(sec_data example-api-app OTHER_WRITER)" = "other" ] && [ ! -e "$sec_state/example-api-app.created" ]; then
  pass "concurrent creation: AlreadyExists is not an error - the keys are merged into the Secret the other writer created, whose own keys stay"
else
  fail "concurrent creation (AlreadyExists)"; grep -v '^::add-mask::' "$WORK/sec.log"
fi
# the other two sources keep their contract: they never create a Secret
sec_reset
if provision "app.DB_PASSWORD=x" || ! grep -qF 'Secret example-api-app does not exist' "$WORK/sec.log" || grep -q ' create ' "$sec_state/calls.log"; then
  fail "app-secrets created a Secret or changed its contract"
else pass "app-secrets is unchanged: a missing Secret is still an error and is never created"; fi
if provision_bundle "$good_dev" "$bn_good_plan" || ! grep -qF 'does not exist' "$WORK/sec.log" || grep -q ' create ' "$sec_state/calls.log"; then
  fail "the declared env-bundle created a Secret or changed its contract"
else pass "the declared env-bundle is unchanged: a missing Secret is still an error and is never created"; fi
sec_reset example-api-app example-api-migrate

# where the values end up in the containers
"$HELM" template example-api "$CHART" --namespace dev-example-api -f "$bn_src/deploy/values.yaml" -f "$bn_src/deploy/values-dev.yaml" \
  --set migration.render=true --set-string migration.runId=t1 >"$WORK/pt-rendered.yaml"
pt_objects="$(yq ea -o=json '[.]' "$WORK/pt-rendered.yaml")"
if [ "$(jq -c '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0] | [((.env // []) | length), ([.envFrom[] | (.configMapRef // .secretRef).name] | join(","))]' <<<"$pt_objects")" = '[0,"example-api-config,example-api-app"]' ]; then
  pass "workloads: no explicit env; envFrom lists the ConfigMap first and the application Secret last, so a key of the Secret overrides the values files"
else
  fail "envFrom order of the workload"
fi
mig_step="$(yq '.jobs.deploy.steps[] | select(.name == "Run the migration Job") | .run' "$dk")"
migbin="$WORK/migbin"; mkdir -p "$migbin"
# A fake cluster on a virtual clock: `date` reads it, `sleep N` advances it - no test really waits.
# $FAKE_STATE/timeline holds "<second> <state>" lines; the Job is in the last state whose second has passed
# (no timeline = complete). The fake records the namespace of the request AND the one inside the object,
# the way the API compares them.
cat >"$migbin/date" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_STATE/clock" 2>/dev/null || echo 0
FAKE
cat >"$migbin/sleep" <<'FAKE'
#!/usr/bin/env bash
now="$(cat "$FAKE_STATE/clock" 2>/dev/null || echo 0)"; echo $(( now + ${1%s} )) >"$FAKE_STATE/clock"
FAKE
cat >"$migbin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "kubectl $*" >>"$FAKE_STATE/mig-calls.log"
now="$(cat "$FAKE_STATE/clock" 2>/dev/null || echo 0)"
state="$(awk -v n="$now" '$1 <= n { s = $2 } END { print s }' "$FAKE_STATE/timeline" 2>/dev/null || true)"; state="${state:-complete}"
if [ "$state" = "late-complete" ]; then   # the first read at this second still sees a running pod
  if grep -qx "$now" "$FAKE_STATE/late" 2>/dev/null; then state=complete; else echo "$now" >>"$FAKE_STATE/late"; state=running; fi
fi
job_json() {
  case "$state" in
    pull|backoff|running|nopod) jq -cn '{status: {active: 1}}' ;;
    pod-done) jq -cn '{status: {succeeded: 1}}' ;;
    complete) jq -cn '{status: {succeeded: 1, conditions: [{type: "SuccessCriteriaMet", status: "True"}, {type: "Complete", status: "True"}]}}' ;;
    failed) jq -cn '{status: {failed: 1, conditions: [{type: "Failed", status: "True", reason: "BackoffLimitExceeded", message: "Job has reached the specified backoff limit"}]}}' ;;
    deadline) jq -cn '{status: {failed: 1, conditions: [{type: "Failed", status: "True", reason: "DeadlineExceeded", message: "Job was active longer than specified deadline"}]}}' ;;
  esac
}
pods_json() {
  local c
  case "$state" in
    nopod) echo '{"items":[]}'; return ;;
    pull) c='{"state": {"waiting": {"reason": "ContainerCreating"}}}' ;;
    backoff) c='{"state": {"waiting": {"reason": "ImagePullBackOff", "message": "Back-off pulling image"}}}' ;;
    running) c='{"state": {"running": {"startedAt": "2026-11-18T10:24:00Z"}}}' ;;
    pod-done|complete) c='{"state": {"terminated": {"reason": "Completed", "exitCode": 0}}}' ;;
    failed) c='{"state": {"terminated": {"reason": "Error", "exitCode": 1}}}' ;;
    deadline) echo '{"items":[]}'; return ;;
  esac
  local phase; case "$state" in pull|backoff) phase=Pending ;; running) phase=Running ;; failed) phase=Failed ;; *) phase=Succeeded ;; esac
  jq -cn --arg p "$phase" --argjson c "$c" '{items: [{metadata: {name: "example-api-migrate-1-1-abcde"}, status: {phase: $p, containerStatuses: [$c]}}]}'
}
case "$*" in
  *"dry-run=client"*) echo "a client-side dry run would place the object in the runner namespace arc-runners" >&2; exit 3 ;;
  "--namespace "*" create -f -")
    doc="$(cat)"; req="$2"; obj="$(jq -r '.metadata.namespace // ""' <<<"$doc")"
    if [ -n "$obj" ] && [ "$obj" != "$req" ]; then
      echo "error: the namespace from the provided object \"$obj\" does not match the namespace \"$req\"" >&2; exit 1
    fi
    printf '%s' "$doc" >"$FAKE_STATE/job.json"; echo "$req" >"$FAKE_STATE/job.ns" ;;
  "--namespace "*" get jobs -l "*" -o json") cat "$FAKE_STATE/existing.json" 2>/dev/null || echo '{"items":[]}' ;;
  "--namespace "*" get job "*" -o json")
    case "$state" in
      api-error) echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2; exit 1 ;;
      forbidden) echo 'Error from server (Forbidden): jobs.batch "example-api-migrate-1-1" is forbidden' >&2; exit 1 ;;
      gone) echo 'Error from server (NotFound): jobs.batch "example-api-migrate-1-1" not found' >&2; exit 1 ;;
    esac
    job_json ;;
  "--namespace "*" get pods -l job-name="*" -o json") pods_json ;;
  "--namespace "*" get pods -l job-name="*" -o name") echo "pod/example-api-migrate-1-1-abcde" ;;
  "--namespace "*" get events "*) printf 'TIME TYPE REASON MESSAGE\n2026-11-18T10:00:00Z Normal Pulling Pulling image\n' ;;
  "--namespace "*" logs job/"*) [ "${FAKE_LOGS:-}" = "fail" ] && { echo "no logs" >&2; exit 1; }; echo "Migrating: 2026_01_01_000000_create_table ... DONE" ;;
  "--namespace "*" patch job "*" --type=merge -p "*) echo "$*" >>"$FAKE_STATE/suspended" ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$migbin/kubectl" "$migbin/date" "$migbin/sleep"; ln -sf "$(command -v "$HELM")" "$migbin/helm"
run_migration_in() {  # directory with deploy/, shadowed names, [namespace], [PATH prefix], [wait seconds]
  rm -f "$sec_state/job.json" "$sec_state/job.ns" "$sec_state/mig-calls.log" "$sec_state/suspended" "$sec_state/late"
  [ -n "${KEEP_CLOCK:-}" ] || echo 0 >"$sec_state/clock"
  echo '{}' >"$WORK/overrides.json"; mkdir -p "$WORK/values"
  yq 'del(.deployment)' "$1/deploy/values.yaml" >"$WORK/values/values.yaml"; yq 'del(.deployment)' "$1/deploy/values-dev.yaml" >"$WORK/values/values-dev.yaml"
  : >"$WORK/mig_summary"
  ( cd "$1" && env -i PATH="${4:-$migbin}:$migbin:$PATH" HOME="$WORK" RUNNER_TEMP="$WORK" GITHUB_STEP_SUMMARY="$WORK/mig_summary" FAKE_STATE="$sec_state" \
      FAKE_LOGS="${FAKE_LOGS:-}" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 RELEASE=example-api NAMESPACE="${3:-dev-example-api}" ENVIRONMENT=dev VALUES_DIR=deploy \
      TIMEOUT=10m MIGRATION_WAIT="${5:-3600}" DIGEST="$good_digest" CHART_DIR="$OLDPWD/$CHART" SHADOWED="$2" bash --noprofile --norc -c "$mig_step" ) </dev/null >"$WORK/mig.log" 2>&1
}
timeline() { printf '%s\n' "$@" | tr ';' '\n' | sed 's/^ *//' >"$sec_state/timeline"; }
rm -f "$sec_state/timeline" "$sec_state/existing.json"
run_migration() { run_migration_in "$bn_src" "$1"; }
job_env() { jq -r '[.spec.template.spec.containers[0].env[] | .name + "=" + .value] | join(" ")' "$sec_state/job.json"; }
if run_migration "" && [ "$(job_env)" = "APP_ENV=dev DB_HOST=db.default.example.test DB_PORT=5432 DB_USERNAME=example_migrator FEATURE_WRITES_ENABLED=false LOG_CHANNEL=stderr" ]; then
  pass "migration Job without a pass-through bundle: created exactly as rendered (other services are unaffected)"
  if [ "$(cat "$sec_state/job.ns")" = "dev-example-api" ] && [ "$(jq -r '.metadata.namespace' "$sec_state/job.json")" = "dev-example-api" ] \
     && ! grep -q 'dry-run' "$sec_state/mig-calls.log" && [ "$(grep -c -- '--namespace dev-example-api' "$sec_state/mig-calls.log")" = "$(wc -l <"$sec_state/mig-calls.log" | tr -d ' ')" ]; then
    pass "the migration Job is created in the application namespace: the request and the object both say dev-example-api (the runner namespace is never involved)"
  else fail "namespace of the migration Job"; cat "$sec_state/mig-calls.log"; fi
else
  fail "migration Job without shadowed names: $(job_env 2>/dev/null)"; cat "$WORK/mig.log"
fi
if run_migration "$pt_shadowed" && [ "$(job_env)" = "APP_ENV=dev DB_PORT=5432 DB_USERNAME=example_migrator LOG_CHANNEL=stderr" ] \
   && [ "$(jq -r '[.spec.template.spec.containers[0].envFrom[].secretRef.name] | join(",")' "$sec_state/job.json")" = "example-api-app,example-api-migrate" ] \
   && [ "$(jq -r '.kind + "/" + .metadata.name' "$sec_state/job.json")" = "Job/example-api-migrate-1-1" ]; then
  pass "migration Job with a pass-through bundle: env entries the Secret provides are dropped (the Secret is not overridden); DB_USERNAME stays the migration role; the migrate Secret is last"
else
  fail "migration Job with shadowed names: $(job_env 2>/dev/null)"; cat "$WORK/mig.log"
fi
# a service with ONE database user: no migrate Secret, no migration.config - the Job must not keep its own DB_USERNAME
one="$WORK/one-user"; rm -rf "$one"; mkdir -p "$one"; cp -R "$bn_src/deploy" "$one/"
yq -i 'del(.requiredSecrets.migrate) | del(.migration.envFromSecrets) | del(.migration.config)' "$one/deploy/values.yaml"; rm -f "$one/deploy/overrides.yaml"
if pt_check dev "$pt_bundle" app "$one" && [ "$(pt_out shadowed)" = "DB_HOST DB_USERNAME FEATURE_WRITES_ENABLED" ] \
   && ! grep -q 'migrate\.' <<<"$(pt_out plan)" && grep -q 'app.DB_MIGRATOR_PASSWORD=DB_MIGRATOR_PASSWORD' <<<"$(pt_out plan)"; then
  pass "single database user: without an alias nothing is planned for a migrate Secret, and DB_USERNAME of the bundle is reported for the migration Job"
else
  fail "single-user plan: plan='$(pt_out plan)' shadowed='$(pt_out shadowed)'"; cat "$WORK/bn.log"
fi
one_shadowed="$(pt_out shadowed)"
if run_migration_in "$one" "$one_shadowed" && [ "$(job_env)" = "APP_ENV=dev DB_PORT=5432 LOG_CHANNEL=stderr" ] \
   && [ "$(jq -r '[.spec.template.spec.containers[0].envFrom[].secretRef.name] | join(",")' "$sec_state/job.json")" = "example-api-app" ]; then
  pass "single database user: the migration Job mounts only the application Secret and keeps no explicit DB_HOST / DB_USERNAME - it connects exactly as the application does"
else
  fail "single-user migration Job: $(job_env 2>/dev/null)"; cat "$WORK/mig.log"
fi
# shellcheck disable=SC2016  # a literal attempt at injection
if run_migration 'DB_HOST;$(id)'; then fail "a malformed list of names was accepted by the migration step"; else pass "migration step refuses a malformed list of names"; fi
if run_migration_in "$bn_src" "" dev-other-namespace && [ "$(cat "$sec_state/job.ns")" = "dev-other-namespace" ] && [ "$(jq -r '.metadata.namespace' "$sec_state/job.json")" = "dev-other-namespace" ]; then
  pass "the migration Job follows the resolved namespace, whatever it is (no fixed or derived namespace)"
else fail "migration Job in another resolved namespace"; cat "$WORK/mig.log"; fi
# a chart that rendered the Job into another namespace: refused before anything is created
fakehelm="$WORK/fakehelm"; mkdir -p "$fakehelm"; cp "$migbin/kubectl" "$fakehelm/kubectl"
printf '#!/usr/bin/env bash
printf "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: example-api-migrate-1-1\n  namespace: arc-runners\nspec: {template: {spec: {containers: [{name: m, image: x}]}}}\n"
' >"$fakehelm/helm"; chmod +x "$fakehelm/helm"
if run_migration_in "$bn_src" "" dev-example-api "$fakehelm"; then fail "a migration Job rendered for another namespace was created"
elif grep -qF "the rendered migration object is 'Job example-api-migrate-1-1 arc-runners', expected Job example-api-migrate-1-1 in dev-example-api - nothing was created" "$WORK/mig.log" \
     && ! grep -q ' create ' "$sec_state/mig-calls.log" 2>/dev/null; then
  pass "a rendered Job that targets another namespace (e.g. arc-runners) is refused before the cluster is asked to create it"
else fail "namespace mismatch of the rendered Job"; cat "$WORK/mig.log"; fi
printf '#!/usr/bin/env bash
printf "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: other\n"
' >"$fakehelm/helm"
if run_migration_in "$bn_src" "" dev-example-api "$fakehelm"; then fail "a non-Job migration object was created"
elif grep -qF "expected Job example-api-migrate-1-1 in dev-example-api" "$WORK/mig.log"; then pass "an object other than the expected Job is refused"
else fail "non-Job migration object"; cat "$WORK/mig.log"; fi

echo "== deploy-k8s.yml: the migration Job is watched until Kubernetes reports it finished"
mig_ok() {  # label, timeline, [wait] -> step must be green
  local label="$1"; timeline "$2"
  if run_migration_in "$bn_src" "" dev-example-api "" "${3:-3600}" && grep -q 'Complete=True after' "$WORK/mig.log" \
     && grep -qF 'succeeded' "$WORK/mig_summary"; then pass "$label"; else fail "$label"; tail -25 "$WORK/mig.log"; fi
}
mig_fail() {  # label, expected text, timeline, [wait] -> step must fail with the text
  local label="$1" text="$2"; timeline "$3"
  if run_migration_in "$bn_src" "" dev-example-api "" "${4:-3600}"; then fail "accepted: $label"; tail -15 "$WORK/mig.log"
  elif grep -qF -- "$text" "$WORK/mig.log"; then pass "$label"
  else fail "failed for another reason: $label"; tail -20 "$WORK/mig.log"; fi
}
mig_ok "an image pull of 24 minutes, then 9 s of migration: the step is green (the old 10-minute limit would have failed it)" "0 pull; 1433 running; 1442 complete"
if [ "$(cat "$sec_state/clock")" -ge 1442 ] && grep -qE 'Complete=True after 14[4-5][0-9] s' "$WORK/mig.log" && ! grep -q '::error::' "$WORK/mig.log"; then
  pass "  ... it waited through the pull (about 1440 s) without an error"
else fail "duration of the 24-minute scenario"; grep -E 'Complete|error' "$WORK/mig.log"; fi
if grep -q 'container waiting: ContainerCreating (image pull or container start in progress)' "$WORK/mig.log" \
   && [ "$(grep -cE '^\[[0-9]{2}:[0-9]{2}\] example-api-migrate-1-1: active=1' "$WORK/mig.log")" -ge 24 ] \
   && [ "$(grep -cE '^\[[0-9]{2}:[0-9]{2}\]' "$WORK/mig.log")" -le 30 ]; then
  pass "  ... ContainerCreating is a waiting state, reported about once a minute (not every poll)"
else fail "progress reporting during the pull"; grep -cE '^\[' "$WORK/mig.log"; fi
if [ "$(grep -c ' get job example-api-migrate-1-1 -o json' "$sec_state/mig-calls.log")" -ge 140 ] && ! grep -q 'logs job/' <(head -n -3 "$sec_state/mig-calls.log"); then
  pass "  ... the Job is polled about every 10 s by its exact name, and no log is requested while the container is not running"
else fail "polling pattern"; fi
mig_ok "a migration that finishes within the configured wait is green" "0 pull; 30 running; 40 complete"
mig_fail "the same 24-minute run with only 10 minutes of wait fails (the limit is the configured wait, nothing else)" "did not start its container within 600 s" "0 pull; 1433 running; 1442 complete" 600
mig_fail "a running pod alone is not success: the Job keeps running past the wait" "the migration may still be changing the database. It is NOT stopped by this workflow" "0 running" 120
if [ ! -e "$sec_state/suspended" ] && ! grep -q ' delete ' "$sec_state/mig-calls.log"; then
  pass "  ... a Job whose container has started is neither deleted nor suspended"
else fail "a started migration was interrupted"; fi
mig_ok "the pod succeeded before the Job reported Complete: the step waits for Complete" "0 running; 50 pod-done; 80 complete"
mig_ok "the pod succeeded at the deadline: a short extension lets the Job report Complete" "0 running; 55 pod-done; 100 complete" 60
mig_ok "Complete appears at the deadline boundary: the final read counts it" "0 running; 60 late-complete" 60
mig_fail "a failed Job fails the step with its reason" "migration Job example-api-migrate-1-1 failed (BackoffLimitExceeded); the upgrade does not run" "0 pull; 20 running; 40 failed"
if grep -q 'condition Failed=True BackoffLimitExceeded' "$WORK/mig.log" && grep -q 'container terminated: Error exit 1' "$WORK/mig.log" \
   && grep -q 'migration output (last 200 lines)' "$WORK/mig.log" && grep -q 'Normal Pulling' "$WORK/mig.log"; then
  pass "  ... with its conditions, container state, events and log"
else fail "diagnostics of a failed Job"; tail -20 "$WORK/mig.log"; fi
mig_fail "ImagePullBackOff until Kubernetes ends the Job: failed with DeadlineExceeded" "failed (DeadlineExceeded)" "0 backoff; 3300 deadline" 3420
if grep -q '::warning::migration Job example-api-migrate-1-1: container waiting with ImagePullBackOff' "$WORK/mig.log" \
   && [ "$(grep -c 'ImagePullBackOff - Kubernetes keeps retrying' "$WORK/mig.log")" = "1" ] \
   && grep -q 'no migration output: the container never started' "$WORK/mig.log" && ! grep -q 'logs job/' "$sec_state/mig-calls.log"; then
  pass "  ... ImagePullBackOff is reported once, and no log is requested from a container that never started"
else fail "ImagePullBackOff diagnostics"; grep -E 'warning|output' "$WORK/mig.log"; fi
mig_ok "transient API errors (four polls) are retried" "0 pull; 20 api-error; 60 complete"
mig_fail "a persistently unreachable API stops the step after a bounded number of retries" "the Kubernetes API did not answer 6 times in a row" "0 api-error"
mig_fail "Forbidden is not swallowed" "the runner may not read Job example-api-migrate-1-1 in dev-example-api (Forbidden / Unauthorized)" "0 pull; 30 forbidden"
mig_fail "a Job that disappears while waiting is detected" "disappeared from dev-example-api before it finished" "0 pull; 50 gone"
mig_fail "the wait ends while the container never started: the Job is suspended, not deleted" "it was suspended so that it cannot start later (the Job object is kept for inspection)" "0 pull" 120
if grep -q 'patch job example-api-migrate-1-1 --type=merge -p {"spec":{"suspend":true}}' "$sec_state/suspended" && ! grep -q ' delete ' "$sec_state/mig-calls.log"; then
  pass "  ... by a suspend patch of exactly that Job"
else fail "suspension of a never-started Job"; fi
FAKE_LOGS=fail mig_fail "an unavailable log does not hide the failure" "failed (BackoffLimitExceeded)" "0 running; 30 failed"
if grep -q '(the log of example-api-migrate-1-1 is not available)' "$WORK/mig.log"; then pass "  ... and is reported as unavailable"; else fail "unavailable log handling"; fi
timeline "0 pull; 1433 running; 1442 complete"; run_migration_in "$bn_src" "" dev-example-api "" 3600
calls_total="$(wc -l <"$sec_state/mig-calls.log" | tr -d ' ')"
if [ "$(grep -c -- '--namespace dev-example-api ' "$sec_state/mig-calls.log")" = "${calls_total}" ] && [ "${calls_total}" -gt 100 ]; then
  pass "every one of the ${calls_total} kubectl calls of the migration step names the application namespace"
else fail "kubectl calls without the namespace"; grep -v -- '--namespace dev-example-api ' "$sec_state/mig-calls.log" | head -3; fi
if [ "$(jq -r '.spec.template.spec.containers[0].image' "$sec_state/job.json")" = "ghcr.io/example-org/example-api@$good_digest" ]; then
  pass "the migration Job runs exactly the image digest of the deployment"
else fail "image of the migration Job"; fi
if ! grep -qE 'DB_HOST=|db\.default\.example\.test|LOG_CHANNEL=|"env"' "$WORK/mig.log"; then
  pass "the step prints no environment variable of the Job (states, reasons and events only)"
else fail "the migration step printed environment values"; fi

# Two runs of one release: a Job that has not finished blocks the next one before it is created.
jq -cn '{items: [{metadata: {name: "example-api-migrate-0-1"}, status: {active: 1}}]}' >"$sec_state/existing.json"
mig_fail "an unfinished migration Job of the same release blocks a second migration" "migration Job(s) example-api-migrate-0-1 of example-api in dev-example-api have not finished; a second migration is not started" "0 complete"
if ! grep -q ' create -f -' "$sec_state/mig-calls.log"; then pass "  ... nothing is created"; else fail "a second migration Job was created"; fi
jq -cn '{items: [{metadata: {name: "a"}, status: {conditions: [{type: "Complete", status: "True"}]}}, {metadata: {name: "b"}, status: {conditions: [{type: "Failed", status: "True"}]}}, {metadata: {name: "c"}, status: {conditions: [{type: "Suspended", status: "True"}]}}]}' >"$sec_state/existing.json"
mig_ok "finished, failed and suspended Jobs of earlier runs do not block" "0 complete"
if grep -qF 'get jobs -l app.kubernetes.io/instance=example-api,app.kubernetes.io/component=migration -o json' "$sec_state/mig-calls.log"; then
  pass "  ... the check looks only at migration Jobs of this release (instance + component labels)"
else fail "selector of the running-migration check"; fi
rm -f "$sec_state/existing.json"

# Green migration -> the upgrade runs with the same digest; red migration -> it does not (GitHub skips the
# remaining steps after a failure: the upgrade step has no `if`).
up_step="$(yq '.jobs.deploy.steps[] | select(.name == "Helm upgrade") | .run' "$dk")"
cat >"$migbin/fakehelm-upgrade" <<'FAKE'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_STATE/helm-calls.log"
FAKE
chmod +x "$migbin/fakehelm-upgrade"; upbin="$WORK/upbin"; mkdir -p "$upbin"; cp "$migbin/fakehelm-upgrade" "$upbin/helm"
deploy_steps() {  # timeline -> runs the migration step, then the upgrade step only if it was green
  rm -f "$sec_state/helm-calls.log"; timeline "$1"
  run_migration_in "$bn_src" "" dev-example-api "" 3600 || return 1
  ( cd "$bn_src" && env -i PATH="$upbin:$PATH" RUNNER_TEMP="$WORK" FAKE_STATE="$sec_state" GITHUB_SHA=abc GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
      RELEASE=example-api NAMESPACE=dev-example-api ENVIRONMENT=dev DIGEST="$good_digest" CHART_DIR=chart ROLLOUT_TIMEOUT=1800 \
      OWNER_LABEL_VALUE=akjet.kz/source-repository=x RESTART=false SECRETS_CHANGED=false bash --noprofile --norc -c "$up_step" ) </dev/null >"$WORK/up.log" 2>&1
}
if [ "$(yq '.jobs.deploy.steps[] | select(.name == "Helm upgrade") | has("if")' "$dk")" = "false" ] \
   && deploy_steps "0 pull; 1433 running; 1442 complete" \
   && grep -qF "image.digest=$good_digest" "$sec_state/helm-calls.log" && grep -qF -- '--timeout 1800s' "$sec_state/helm-calls.log"; then
  pass "a green migration continues to helm upgrade with the same digest and the rollout timeout of the values"
else fail "upgrade after a green migration"; cat "$WORK/up.log" "$sec_state/helm-calls.log" 2>/dev/null; fi
if deploy_steps "0 running; 30 failed"; then fail "the upgrade ran after a failed migration"
elif [ ! -e "$sec_state/helm-calls.log" ]; then pass "a failed migration stops the deployment: helm upgrade does not run"
else fail "helm upgrade ran after a failed migration"; fi
if [ "$(yq '.jobs.deploy.steps[] | select(.name == "Verify the rollout") | has("if")' "$dk")" = "false" ]; then
  pass "the rollout verification follows the upgrade (no condition that could skip it)"
else fail "rollout verification condition"; fi

echo "== deploy-k8s.yml: migration wait and rollout timeout come from the values"
id_values $'deployment:\n  release: example-api\n  migrationWaitTimeoutSeconds: 3600\n  rolloutTimeoutSeconds: 1800' $'deployment:\n  namespace: dev-example-api'
if id_run dev && [ "$(id_out migration-wait)/$(id_out rollout-timeout)" = "3600/1800" ]; then
  pass "deployment.migrationWaitTimeoutSeconds and deployment.rolloutTimeoutSeconds are read from the values"
else fail "timeouts from values"; cat "$WORK/id.log"; fi
id_values "$base_common" $'deployment:\n  namespace: dev-example-api'
if id_run dev && [ "$(id_out migration-wait)/$(id_out rollout-timeout)" = "/600" ]; then
  pass "without them: no fixed migration wait (derived from the Job deadline later) and the rollout timeout of the input (10m)"
else fail "timeout defaults: $(id_out migration-wait)/$(id_out rollout-timeout)"; fi
for bad in 0 30 5401 '"3600"' 1.5 -60; do
  id_values $'deployment:\n  release: example-api\n  migrationWaitTimeoutSeconds: '"$bad" $'deployment:\n  namespace: dev-example-api'
  id_reject "migrationWaitTimeoutSeconds: $bad" "deployment.migrationWaitTimeoutSeconds must be a whole number of seconds between 60 and 5400" dev
done
id_values $'deployment:\n  release: example-api\n  rolloutTimeoutSeconds: 7200' $'deployment:\n  namespace: dev-example-api'
id_reject "rolloutTimeoutSeconds: 7200" "deployment.rolloutTimeoutSeconds must be a whole number of seconds between 60 and 3600" dev

render_step="$(yq '.jobs.validate.steps[] | select(.id == "render") | .run' "$dk")"
render_run() {  # directory, migration wait, rollout timeout, run-migrations -> outputs in $WORK/render_output
  : >"$WORK/render_output"; rm -rf "$WORK/rt"; mkdir -p "$WORK/rt/values"; echo '{}' >"$WORK/rt/overrides.json"
  yq 'del(.deployment)' "$1/deploy/values.yaml" >"$WORK/rt/values/values.yaml"; yq 'del(.deployment)' "$1/deploy/values-dev.yaml" >"$WORK/rt/values/values-dev.yaml"
  ( cd "$1" && env -i PATH="$PATH" HOME="$WORK" RUNNER_TEMP="$WORK/rt" GITHUB_OUTPUT="$WORK/render_output" ENVIRONMENT=dev DIGEST="$good_digest" \
      CHART_VERSION=0.1.0 VALUES_DIR=deploy RUN_MIGRATIONS="$4" NAMESPACE=dev-example-api RELEASE=example-api CHART="$OLDPWD/$CHART" GITHUB_TOKEN=x \
      MIGRATION_WAIT="$2" ROLLOUT_TIMEOUT="$3" DEPLOY_JOB_SECONDS="$(yq '.env.DEPLOY_JOB_SECONDS' "$OLDPWD/$dk")" \
      DEPLOY_OVERHEAD_SECONDS="$(yq '.env.DEPLOY_OVERHEAD_SECONDS' "$OLDPWD/$dk")" bash --noprofile --norc -c "$render_step" ) </dev/null >"$WORK/render.log" 2>&1
}
rw="$WORK/render-src"; rm -rf "$rw"; mkdir -p "$rw"; cp -R "$bn_src/deploy" "$rw/"; yq -i '.migration.activeDeadlineSeconds = 3300' "$rw/deploy/values.yaml"
if render_run "$rw" 3600 1800 true && grep -qx 'migration-wait=3600' "$WORK/render_output"; then
  pass "Job deadline 3300 s, watched for 3600 s, rollout 1800 s: accepted (the backend DEV values)"
else fail "backend-like timeouts"; tail -5 "$WORK/render.log"; fi
if render_run "$rw" "" 600 true && grep -qx 'migration-wait=3420' "$WORK/render_output"; then
  pass "without a configured wait the Job is watched for its deadline plus 120 s (3300 -> 3420)"
else fail "derived migration wait"; tail -5 "$WORK/render.log"; fi
if render_run "$rw" 3300 600 true; then fail "a wait that does not outlast the Job deadline was accepted"
elif grep -qF 'migration.activeDeadlineSeconds (3300) must end at least 60 s before deployment.migrationWaitTimeoutSeconds (3300)' "$WORK/render.log"; then
  pass "a Job that could outlive the watch is refused before any cluster access"
else fail "deadline / wait check"; tail -3 "$WORK/render.log"; fi
yq -i '.migration.activeDeadlineSeconds = 5300' "$rw/deploy/values.yaml"
if render_run "$rw" 5400 3600 true; then fail "a configuration beyond the deploy job budget was accepted"
elif grep -qF 'exceed the deploy job budget of 7200 s' "$WORK/render.log"; then pass "migration wait + rollout + overhead beyond the 120-minute deploy job are refused"
else fail "budget check"; tail -3 "$WORK/render.log"; fi
if render_run "$rw" "" 600 false && grep -qx 'migration-wait=0' "$WORK/render_output"; then
  pass "a deployment without migrations is unaffected (no migration wait)"
else fail "render without migrations"; tail -3 "$WORK/render.log"; fi
if [ "$(yq '.jobs.deploy.timeout-minutes' "$dk")" = "$(( $(yq '.env.DEPLOY_JOB_SECONDS' "$dk") / 60 ))" ] && [ "$(yq '.jobs.deploy.timeout-minutes' "$dk")" = "120" ]; then
  pass "the deploy job timeout (120 min) equals the budget the validate job checks"
else fail "deploy job timeout and budget differ"; fi
# shellcheck disable=SC2016  # literal workflow text
if [ "$(yq '.jobs.deploy.concurrency.group' "$dk")" = 'deploy-k8s-dev-${{ needs.validate.outputs.namespace }}-${{ needs.validate.outputs.release }}' ] \
   && [ "$(yq '.jobs.deploy.concurrency.cancel-in-progress' "$dk")" = "false" ]; then
  pass "one deployment per resolved target (namespace + release) at a time; a running one is never cancelled"
else fail "concurrency key"; fi
if ! grep -nE 'TIMEOUT%\[sm\]' <<<"$mig_step"; then pass "the migration wait no longer uses the Helm timeout input"; else fail "the migration step still uses the Helm timeout"; fi

echo "== deploy-k8s.yml: the deploy job re-reads the target and checks release ownership"
prep_step="$(yq '.jobs.deploy.steps[] | select(.name == "Prepare values") | .run' "$dk")"
prep() {  # directory, NAMESPACE, RELEASE
  rm -rf "$WORK/prep"; mkdir -p "$WORK/prep"
  ( cd "$1" && env -i PATH="$PATH" RUNNER_TEMP="$WORK/prep" ENVIRONMENT=dev VALUES_DIR=deploy NAMESPACE="$2" RELEASE="$3" \
      bash --noprofile --norc -c "$prep_step" ) </dev/null >"$WORK/prep.log" 2>&1
}
id_values "$base_common" $'deployment:\n  namespace: dev-example-api\nconfig:\n  A: "1"'
if prep "$idw" dev-example-api example-api && [ "$(yq -o=json -I0 '.' "$WORK/prep/values/values-dev.yaml")" = '{"config":{"A":"1"}}' ] \
   && [ "$(yq '.deployment' "$WORK/prep/values/values.yaml")" = "null" ]; then
  pass "deploy job: the same commit resolves to the same namespace and release; Helm gets the values without deployment"
else fail "deploy job values preparation"; cat "$WORK/prep.log"; fi
if prep "$idw" dev-other example-api; then fail "a namespace that differs from the validate job was accepted"
elif grep -qF "the values resolve to 'dev-example-api example-api', the validate job resolved 'dev-other example-api'" "$WORK/prep.log"; then
  pass "deploy job: a namespace different from the validate job stops the deployment before the first cluster request"
else fail "namespace mismatch between the jobs"; cat "$WORK/prep.log"; fi
if prep "$idw" "" ""; then fail "an empty target was accepted by the deploy job"; else pass "deploy job: an empty namespace / release is refused"; fi

own_step="$(yq '.jobs.deploy.steps[] | select(.id == "owner") | .run' "$dk")"
ownbin="$WORK/ownbin"; mkdir -p "$ownbin"
cat >"$ownbin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
case "$*" in
  "--namespace "*" get configmaps -l owner=helm,name="*" -o json")
    case "${FAKE_RECORDS:-}" in
      forbidden) echo 'Error from server (Forbidden): configmaps is forbidden' >&2; exit 1 ;;
      unreachable) echo 'Unable to connect to the server: EOF' >&2; exit 1 ;;
      none) echo '{"items":[]}' ;;
      unlabelled) echo '{"items":[{"metadata":{"labels":{"owner":"helm","name":"x","version":"1"}}}]}' ;;
      *) jq -cn --arg v "$FAKE_RECORDS" '{items: [{metadata: {labels: {owner: "helm", version: "1", "akjet.kz/source-repository": $v}}}]}' ;;
    esac ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$ownbin/kubectl"
own() {  # records, repository
  : >"$WORK/own_output"; : >"$WORK/own-calls.log"
  env -i PATH="$ownbin:$PATH" FAKE_LOG="$WORK/own-calls.log" FAKE_RECORDS="$1" GITHUB_OUTPUT="$WORK/own_output" GITHUB_REPOSITORY="$2" \
    OWNER_LABEL="$(yq '.env.OWNER_LABEL' "$dk")" NAMESPACE=dev-shared RELEASE=backend bash --noprofile --norc -c "$own_step" </dev/null >"$WORK/own.log" 2>&1
}
if own none Akjet-dev/backend && [ "$(cat "$WORK/own_output")" = "label=akjet.kz/source-repository=Akjet-dev.backend" ] && grep -q -- '--namespace dev-shared' "$WORK/own-calls.log"; then
  pass "a new release is assigned to the deploying repository (Helm release label akjet.kz/source-repository)"
else fail "ownership of a new release"; cat "$WORK/own.log"; fi
if own unlabelled Akjet-dev/backend && grep -q 'carries no owner label yet' "$WORK/own.log"; then
  pass "a release installed by an earlier version (no label) is adopted by its next deployment"
else fail "adoption of an unlabelled release"; fi
if own Akjet-dev.backend Akjet-dev/backend; then pass "the owning repository deploys its release again"; else fail "the owner was refused"; cat "$WORK/own.log"; fi
if own Akjet-dev.backend Akjet-dev/lk-frontend; then fail "another repository was allowed to take over a release"
elif grep -qF "release backend in dev-shared belongs to Akjet-dev.backend, not to Akjet-dev/lk-frontend" "$WORK/own.log"; then
  pass "shared namespace: a repository whose values name another service's release is stopped before any change"
else fail "foreign release"; cat "$WORK/own.log"; fi
if own forbidden Akjet-dev/backend; then fail "Forbidden was ignored"; elif grep -q 'may not list the Helm release records' "$WORK/own.log"; then pass "ownership: Forbidden is reported as a missing permission"; else fail "ownership Forbidden"; fi
if own unreachable Akjet-dev/backend; then fail "an unreachable API was ignored"; elif grep -q 'the Kubernetes API did not answer' "$WORK/own.log"; then pass "ownership: an unreachable API is not treated as 'no release'"; else fail "ownership unreachable"; fi
if own none "Example-Org/$(printf 'r%.0s' $(seq 1 70))" && grep -qE '^label=akjet.kz/source-repository=sha256-[0-9a-f]{40}$' "$WORK/own_output"; then
  pass "a repository name too long for a label value is recorded as its hash"
else fail "long repository name"; cat "$WORK/own_output"; fi
# shellcheck disable=SC2016  # literal workflow text
if [ "$(yq '.jobs.deploy.steps[] | select(.name == "Helm upgrade") | .env.OWNER_LABEL_VALUE' "$dk")" = '${{ steps.owner.outputs.label }}' ] \
   && grep -qF -- '--labels "${OWNER_LABEL_VALUE}"' "$dk"; then
  pass "helm upgrade records the owner on the release"
else fail "owner label on helm upgrade"; fi
steps_order="$(yq '[.jobs.deploy.steps[].name] | join("|")' "$dk")"
case "$steps_order" in
  *"Prepare values|"*"Check release ownership|"*"Provision application Secrets|Run the migration Job|Helm upgrade"*)
    pass "order: values re-read, ownership checked, then Secrets, migration and upgrade" ;;
  *) fail "order of the deploy steps: $steps_order" ;;
esac

echo "== consumers: every application repository against the candidate workflows"
cc=(python3 tests/check_consumers.py)
if "${cc[@]}" >"$WORK/consumers.log" 2>&1; then
  pass "committed consumer snapshots (tests/consumers/*.json) satisfy the candidate interfaces"
else
  fail "a consumer snapshot is not compatible with the candidate"; cat "$WORK/consumers.log"
fi
if [ "$(yq -r '.consumers | length' tests/consumers.yaml)" = "$(find tests/consumers -name '*.json' | wc -l | tr -d ' ')" ]; then
  pass "every consumer of tests/consumers.yaml has a snapshot"
else
  fail "consumers without a snapshot (or snapshots without a consumer)"
fi
# The real callers: a workspace with sibling checkouts (local), or fetched with a read-only token (CI).
ws="${AKJET_WORKSPACE:-}"
if [ -z "$ws" ] && [ -n "${CONSUMERS_READ_TOKEN:-}" ]; then
  if tests/fetch-consumers.sh "$WORK/consumers-src" >"$WORK/fetch.log" 2>&1; then ws="$WORK/consumers-src"; else fail "fetching the consumers"; cat "$WORK/fetch.log"; fi
fi
if [ -z "$ws" ]; then
  ws=..; for n in $(yq -r '.consumers[].name' tests/consumers.yaml); do [ -d "../$n/.github/workflows" ] || ws=""; done
fi
if [ -n "$ws" ]; then
  if "${cc[@]}" --workspace "$ws" --fail-on-stale-snapshot --against-pinned --report "$WORK/consumers-report.txt" >"$WORK/consumers.log" 2>&1; then
    pass "real callers of all consumers ($ws): interfaces, permissions, namespaces, Helm values, Docker build contract, opt-in behaviour; snapshots are current"
  else
    fail "a real consumer is not compatible with the candidate (or a snapshot is stale)"
  fi
  sed 's/^/      /' "$WORK/consumers.log"
else
  echo "      real callers not available (no workspace, no CONSUMERS_READ_TOKEN): only the snapshots were validated"
fi

# The checker itself: a synthetic consumer built from the caller templates, then one defect at a time.
syn="$WORK/syn"; rm -rf "$syn"; mkdir -p "$syn/ws/example-api/.github/workflows" "$syn/snap"
pin="1234567890abcdef1234567890abcdef12345678"
for t in "${templates[@]}"; do
  sed -e 's#example-org/ci/#Akjet-dev/ci/#' -e "s#<CI_COMMIT>#$pin#" "$t" >"$syn/ws/example-api/.github/workflows/$(basename "$t")"
done
cp -R tests/secrets/deploy "$syn/ws/example-api/deploy"; printf 'FROM scratch\n' >"$syn/ws/example-api/Dockerfile"
yq -i '.deployment.release = "example-api" | .image.repository = "ghcr.io/example-org/example-api"' "$syn/ws/example-api/deploy/values.yaml"
for e in dev stage; do yq -i ".deployment.namespace = \"$e-example-api\"" "$syn/ws/example-api/deploy/values-$e.yaml"; done
printf 'consumers:\n  - { name: example-api, repository: Example-Org/example-api, ref: dev-k8s/release, namespace: { dev: dev-example-api, stage: stage-example-api } }\n' >"$syn/manifest.yaml"
syn_check() { "${cc[@]}" --manifest "$syn/manifest.yaml" --snapshots "$syn/snap" --workspace "$syn/ws" "$@" >"$WORK/syn.log" 2>&1; }
if syn_check --write-snapshots --strict-sha && syn_check --fail-on-stale-snapshot; then
  pass "the caller templates of examples/service-repo satisfy the candidate interfaces"
else
  fail "caller templates against the candidate"; cat "$WORK/syn.log"
fi
# shellcheck disable=SC2016  # literal GitHub expressions inside a yq program
yq -i '.jobs.deploy-dev.secrets = {"app-secrets": "app.DB_PASSWORD=${{ secrets.DEV_DB_PASSWORD }}\nmigrate.DB_PASSWORD?=${{ secrets.DEV_DB_MIGRATOR_PASSWORD }}\n"}' "$syn/ws/example-api/.github/workflows/k8s-deploy.yml"
if syn_check; then pass "explicit app-secrets on the deploying call are accepted (services that do not use a bundle)"; else fail "app-secrets caller"; cat "$WORK/syn.log"; fi
# shellcheck disable=SC2016
yq -i '.jobs.deploy-dev.secrets = {"env-bundle": "${{ secrets.DEV_API_ENV }}"}' "$syn/ws/example-api/.github/workflows/k8s-deploy.yml"
if syn_check; then pass "an env-bundle on the deploying call is accepted (services with many variables)"; else fail "env-bundle caller"; cat "$WORK/syn.log"; fi
yq -i 'del(.jobs.deploy-dev.secrets)' "$syn/ws/example-api/.github/workflows/k8s-deploy.yml"
if syn_check; then pass "a caller without any runtime secret is accepted (static frontends)"; else fail "caller without secrets"; cat "$WORK/syn.log"; fi
sed -i.bak "s#$pin#abcdefabcdefabcdefabcdefabcdefabcdefabcd#" "$syn/ws/example-api/.github/workflows/k8s-deploy.yml"
if syn_check --fail-on-stale-snapshot; then pass "moving a consumer to another revision does not make its snapshot stale"; else fail "snapshot staleness on a revision change"; cat "$WORK/syn.log"; fi
mv "$syn/ws/example-api/.github/workflows/k8s-deploy.yml.bak" "$syn/ws/example-api/.github/workflows/k8s-deploy.yml"
syn_defect() {  # label, expected text, file, yq edit
  local label="$1" text="$2" file="$syn/ws/example-api/.github/workflows/$3"
  cp "$file" "$WORK/syn-backup.yml"; yq -i "$4" "$file"
  if syn_check; then fail "not detected: $label"
  elif grep -qF -- "$text" "$WORK/syn.log"; then pass "detected: $label"
  else fail "detected for another reason: $label"; grep ERROR "$WORK/syn.log"; fi
  cp "$WORK/syn-backup.yml" "$file"
}
syn_defect "a secret the referenced workflow does not define (the 'Invalid secret' start-up failure)" \
  "Invalid secret, legacy-secrets is not defined in the referenced workflow" k8s-deploy.yml '.jobs.deploy-dev.secrets."legacy-secrets" = "x"'
syn_defect "an input the referenced workflow does not define" "input 'namespace' is not defined" k8s-deploy.yml '.jobs.deploy-dev.with.namespace = "other"'
syn_defect "a missing required input" "required input 'chart-version' is missing" k8s-deploy.yml 'del(.jobs.deploy-dev.with."chart-version")'
syn_defect "a string where a boolean is declared" "input 'validate-only' must be boolean" k8s-build.yml '.jobs.validate.with."validate-only" = "true"'
syn_defect "secrets: inherit" "secrets: inherit" k8s-deploy.yml '.jobs.deploy-dev.secrets = "inherit"'
# shellcheck disable=SC2016  # literal GitHub expression inside a yq program
syn_defect "an output the referenced workflow does not provide" "output 'tag' is not defined" k8s-build.yml '.jobs.deploy-dev.with.digest = "${{ needs.image.outputs.tag }}"'
syn_defect "a caller job without packages: read (private chart)" "the referenced workflow needs packages: read" k8s-deploy.yml '.jobs.deploy-dev.permissions = {"contents": "read"}'
syn_defect "a build call without packages: write" "the referenced workflow needs packages: write" k8s-build.yml '.jobs.image.permissions.packages = "read"'
syn_defect "a mutable reference instead of a commit SHA" "is not a full commit SHA" k8s-deploy.yml '.jobs.deploy-dev.uses = "Akjet-dev/ci/.github/workflows/deploy-k8s.yml@main"'
syn_defect "a reusable workflow that does not exist" "has no reusable workflow sync-secrets.yml" k8s-deploy.yml '.jobs.deploy-dev.uses = "Akjet-dev/ci/.github/workflows/sync-secrets.yml@'"$pin"'"'
# shellcheck disable=SC2016  # literal GitHub expression inside a yq program
syn_defect "runtime secrets on a validate-only call" "app-secrets passed to a validate-only call" k8s-build.yml '.jobs.validate.secrets."app-secrets" = "app.DB_PASSWORD=${{ secrets.DEV_DB_PASSWORD }}"'
# shellcheck disable=SC2016  # literal GitHub expression inside a yq program
syn_defect "app-secrets together with env-bundle" "app-secrets and env-bundle are passed together" k8s-deploy.yml '.jobs.deploy-dev.secrets = {"app-secrets": "app.DB_PASSWORD=${{ secrets.DEV_DB_PASSWORD }}", "env-bundle": "${{ secrets.DEV_API_ENV }}"}'
# shellcheck disable=SC2016  # literal GitHub expression inside a yq program
syn_defect "a secret of another environment in the dev deployment" "reads secrets of another environment: STAGE_API_ENV" k8s-deploy.yml '.jobs.deploy-dev.secrets = {"env-bundle": "${{ secrets.STAGE_API_ENV }}"}'
syn_defect "another chart version than the candidate ships" "chart-version 9.9.9 != charts/akjet-app" k8s-deploy.yml '.jobs.deploy-dev.with."chart-version" = "9.9.9"'
syn_defect "a call of a local workflow that is not reusable" "K7" k8s-build.yml '.jobs.extra = {"uses": "./.github/workflows/k8s-deploy.yml", "with": {"digest": "x"}, "permissions": {"contents": "read"}}'
# shellcheck disable=SC2016  # literal GitHub expression inside a yq program
syn_defect "a BuildKit secret passed that the Dockerfile never mounts" "passes secrets ['COMPOSER_AUTH'] that the Dockerfile never mounts" k8s-build.yml '.jobs.image.secrets."build-secrets" = "COMPOSER_AUTH=${{ secrets.X }}"'
yq -i '.consumers[0].namespace.dev = "dev-other"' "$syn/manifest.yaml"
if syn_check; then fail "not detected: namespace drift between the values and the platform"
elif grep -qF "values-dev.yaml targets namespace dev-example-api, the platform provides dev-other" "$WORK/syn.log"; then pass "detected: the namespace in the values differs from what the platform provides"
else fail "namespace drift detected for another reason"; fi
yq -i '.consumers[0].namespace.dev = "dev-example-api"' "$syn/manifest.yaml"
syn_values_defect() {  # label, expected text, file under deploy/, yq edit
  local label="$1" text="$2" file="$syn/ws/example-api/deploy/$3"
  cp "$file" "$WORK/syn-backup.yml"; yq -i "$4" "$file"
  if syn_check; then fail "not detected: $label"
  elif grep -qF -- "$text" "$WORK/syn.log"; then pass "detected: $label"
  else fail "detected for another reason: $label"; grep ERROR "$WORK/syn.log"; fi
  cp "$WORK/syn-backup.yml" "$file"
}
syn_values_defect "a consumer without deployment.namespace" "deployment.namespace is not set" values-dev.yaml 'del(.deployment)'
syn_values_defect "a consumer whose DEV values name a STAGE namespace" "does not belong to the environment dev" values-dev.yaml '.deployment.namespace = "stage-example-api"'
syn_values_defect "a consumer without deployment.release" "deployment.release is not set" values.yaml 'del(.deployment.release)'
syn_values_defect "a consumer without image.repository" "K12 example-api: image.repository" values.yaml 'del(.image.repository)'
syn_values_defect "an image outside the owner's registry namespace" "must name an image under ghcr.io/example-org/" values.yaml '.image.repository = "docker.io/library/nginx"'
printf 'consumers:\n  - { name: example-api, repository: Example-Org/example-api, ref: dev-k8s/release, namespace: { dev: dev-example-api, stage: stage-example-api } }\n  - { name: example-two, repository: Example-Org/example-two, ref: dev-k8s/release, namespace: { dev: dev-example-api, stage: stage-example-api } }\n' >"$syn/manifest.yaml"
cp -R "$syn/ws/example-api" "$syn/ws/example-two"; yq -i '.image.repository = "ghcr.io/example-org/example-two"' "$syn/ws/example-two/deploy/values.yaml"
if syn_check --write-snapshots; then fail "two services with the same release in one namespace were accepted"
elif grep -qF "K11 dev namespace dev-example-api: example-api=example-api, example-two=example-api" "$WORK/syn.log"; then pass "detected: two services that share a namespace but declare the same release"
else fail "shared namespace / same release"; grep ERROR "$WORK/syn.log"; fi
yq -i '.deployment.release = "example-two"' "$syn/ws/example-two/deploy/values.yaml"
if syn_check --write-snapshots; then pass "two services in one namespace with their own releases are accepted (backend + lk-frontend model)"; else fail "shared namespace, separate releases"; grep ERROR "$WORK/syn.log"; fi
rm -rf "$syn/ws/example-two" "$syn/snap/example-two.json"
printf 'consumers:\n  - { name: example-api, repository: Example-Org/example-api, ref: dev-k8s/release, namespace: { dev: dev-example-api, stage: stage-example-api } }\n' >"$syn/manifest.yaml"
sed -i.bak "s#$pin#0000000000000000000000000000000000000000#" "$syn/ws/example-api/.github/workflows/k8s-deploy.yml"
if syn_check && grep -q 'PENDING' "$WORK/syn.log" && ! syn_check --strict-sha && grep -q 'K10 consumers pin different revisions\|all-zero placeholder' "$WORK/syn.log"; then
  pass "the zero placeholder and mixed revisions are reported, and refused in strict mode"
else
  fail "placeholder / mixed revisions"; cat "$WORK/syn.log"
fi
mv "$syn/ws/example-api/.github/workflows/k8s-deploy.yml.bak" "$syn/ws/example-api/.github/workflows/k8s-deploy.yml"

# scripts/update-ci-sha.sh on a throw-away clone: the candidate becomes a commit on origin/main THERE only.
if git rev-parse --git-dir >/dev/null 2>&1; then
  up="$WORK/up"; rm -rf "$up"; mkdir -p "$up"
  git clone --quiet --no-hardlinks . "$up/ci" 2>/dev/null
  ( cd "$up/ci" && git checkout --quiet --detach 2>/dev/null && git remote remove origin
    ( cd "$OLDPWD" && COPYFILE_DISABLE=1 tar --exclude=.git -cf - . ) | tar -xf -
    cp "$syn/manifest.yaml" tests/consumers.yaml
    git add -A && git -c user.name=test -c user.email=test@example.test commit --quiet -m candidate
    git update-ref refs/remotes/origin/main HEAD ) >"$WORK/up-setup.log" 2>&1
  new_sha="$(git -C "$up/ci" rev-parse HEAD)"
  cp -R "$syn/ws/example-api" "$up/example-api"
  printf 'jobs:\n  legacy:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - uses: Akjet-dev/ci/netbird@c0f048ff11eda0ffb2817d4ef98d9183b831046d\n' >"$up/example-api/.github/workflows/deploy.yml"
  ( cd "$up/example-api" && git init --quiet && git add -A && git -c user.name=test -c user.email=test@example.test commit --quiet -m base ) >/dev/null 2>&1
  before="$(cat "$up/example-api/.github/workflows/"*.yml | shasum | cut -d' ' -f1)"
  if ( cd "$up/ci" && scripts/update-ci-sha.sh "$new_sha" ) >"$WORK/up.log" 2>&1 && grep -q 'dry run: 2 file(s) would change' "$WORK/up.log" \
     && [ "$(cat "$up/example-api/.github/workflows/"*.yml | shasum | cut -d' ' -f1)" = "$before" ]; then
    pass "update-ci-sha.sh: the default is a dry run that shows the diff and changes nothing"
  else
    fail "update-ci-sha.sh dry run"; cat "$WORK/up.log" "$WORK/up-setup.log"
  fi
  ( cd "$up/ci" && scripts/update-ci-sha.sh "$new_sha" --apply ) >"$WORK/up.log" 2>&1 && up_rc=0 || up_rc=$?
  up_refs="$(grep -h 'uses: Akjet-dev/ci/.github/workflows/' "$up/example-api/.github/workflows/"k8s-*.yml | grep -c "@$new_sha" || true)"
  up_old="$(grep -h '^ *uses:' "$up/example-api/.github/workflows/"k8s-*.yml | grep -c "$pin" || true)"
  up_other="$(git -C "$up/example-api" status --porcelain | grep -vc 'k8s-' || true)"
  up_lines="$(git -C "$up/example-api" diff --numstat | awk '{a+=$1; d+=$2} END {print a "/" d}')"
  up_commits="$(git -C "$up/example-api" rev-list --count HEAD)"
  if [ "$up_rc/$up_refs/$up_old/$up_other/$up_lines/$up_commits" = "0/4/0/0/4/4/1" ]; then
    pass "update-ci-sha.sh --apply: exactly the four shared-workflow references change; other actions and files are untouched; nothing is committed"
  else
    fail "update-ci-sha.sh --apply (rc/refs/old/other files/lines/commits = $up_rc/$up_refs/$up_old/$up_other/$up_lines/$up_commits)"; tail -5 "$WORK/up.log"
  fi
  up_reject() {  # label, expected text, argument
    if ( cd "$up/ci" && scripts/update-ci-sha.sh "$3" --apply ) >"$WORK/up.log" 2>&1; then fail "update-ci-sha.sh accepted: $1"
    elif grep -qF -- "$2" "$WORK/up.log"; then pass "update-ci-sha.sh refuses $1"; else fail "update-ci-sha.sh refused for another reason: $1"; cat "$WORK/up.log"; fi
  }
  up_reject "a branch name" "full 40-character commit SHA" main
  up_reject "a short SHA" "full 40-character commit SHA" "${new_sha:0:12}"
  up_reject "the zero placeholder" "zero placeholder" 0000000000000000000000000000000000000000
  up_reject "a revision that does not exist" "is not a commit of this repository" 1111111111111111111111111111111111111111
  unmerged="$( cd "$up/ci" && git -c user.name=test -c user.email=test@example.test commit --quiet --allow-empty -m unmerged && git rev-parse HEAD )"
  up_reject "a commit that is not on origin/main" "is not part of origin/main" "$unmerged"
  ( cd "$up/example-api" && git checkout --quiet -- . && yq -i '.jobs.deploy-dev.secrets."legacy-secrets" = "x"' .github/workflows/k8s-deploy.yml )
  up_reject "an update while a consumer is incompatible with that revision" "not compatible with $new_sha" "$new_sha"
  if [ -z "$(git -C "$up/example-api" diff --stat -- .github/workflows/k8s-build.yml)" ]; then pass "  ... and leaves every file as it was"; else fail "files changed although the update was refused"; fi
fi

echo "== branch model: Kubernetes workflows next to the existing deployment"
bm="$WORK/branch-model"; mkdir -p "$bm/ok"
cp tests/branch-model/legacy/deploy.yml "${templates[@]}" "$bm/ok/"
if python3 tests/check_branch_model.py "$bm/ok" --legacy-branch dev/v2 >"$WORK/bm.log" 2>&1; then
  pass "templates next to an existing deploy.yml satisfy the branch model"
else
  fail "branch model of the templates"; cat "$WORK/bm.log"
fi
triggers() { awk -v b="$1" '$1 == b && $2 == "->" { print $3 }' "$WORK/bm.log"; }
if [ "$(triggers main)" = "deploy.yml" ] && [ "$(triggers dev/v1)" = "deploy.yml" ] && [ "$(triggers dev/v2)" = "-" ]; then
  pass "push to main and to dev/v1 triggers only the existing deploy.yml; dev/v2 triggers nothing"
else
  fail "legacy branches trigger: main='$(triggers main)' dev/v1='$(triggers dev/v1)' dev/v2='$(triggers dev/v2)'"
fi
if [ "$(triggers dev-k8s/release)" = "k8s-build.yml" ] && [ "$(triggers stage-k8s/release)" = "k8s-build.yml" ] \
   && [ "$(triggers dev-k8s/feature-example)" = "k8s-build.yml" ] && [ "$(triggers stage-k8s/feature-example)" = "k8s-build.yml" ] \
   && [ "$(triggers dev/k8s)" = "-" ] && [ "$(triggers feature/example)" = "-" ]; then
  pass "dev-k8s/* and stage-k8s/* trigger only k8s-build.yml; dev/k8s and other branches trigger nothing"
else
  fail "kubernetes branches trigger"; cat "$WORK/bm.log"
fi
build_tpl="${templates[0]}"
if [ "$(yq '[.jobs[] | select(.uses != null and (.uses | test("deploy-k8s")) and .with."validate-only" != true)] | length' "$build_tpl")" = "1" ] \
   && [ "$(yq '.jobs.deploy-dev.with.environment' "$build_tpl")" = "dev" ]; then
  pass "k8s-build.yml has exactly one deploying job and it targets dev"
else
  fail "deploying jobs in the template"
fi
for case_file in tests/branch-model/bad/*.yml; do
  name="$(basename "$case_file" .yml)"
  expected="$(sed -n 's/^# expect: //p' "$case_file")"
  mkdir -p "$bm/$name" && cp "$case_file" "$bm/$name/$(sed -n 's/^# as: //p' "$case_file")"
  if python3 tests/check_branch_model.py "$bm/$name" >"$WORK/bm-bad.log" 2>&1; then
    fail "$name: was accepted"
  elif grep -qF -- "$expected" "$WORK/bm-bad.log"; then
    pass "$name: rejected"
  else
    fail "$name: rejected for another reason"; cat "$WORK/bm-bad.log"
  fi
done

echo "== existing server deployment is untouched"
legacy_files=(.github/workflows/deploy.yml netbird/action.yml)
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git diff --quiet HEAD -- "${legacy_files[@]}"; then
    pass "deploy.yml and netbird/action.yml are identical to the committed versions"
  else
    fail "an existing deployment file was modified"
  fi
fi
if [ "$(yq '.on | keys | join(",")' .github/workflows/deploy.yml)" = "workflow_call" ] \
   && ! grep -qE 'helm|kubectl|deploy-k8s|build-image' "${legacy_files[@]}"; then
  pass "deploy.yml is still a workflow_call interface with no Kubernetes steps"
else
  fail "existing deploy.yml interface"
fi
if grep -lE 'uses: +(\./)?\.github/workflows/deploy\.yml|/netbird@' "${new_workflows[@]}" "${templates[@]}" >"$WORK/cross.log"; then
  fail "a Kubernetes workflow depends on the existing server deployment"; cat "$WORK/cross.log"
else
  pass "Kubernetes workflows do not depend on the existing deploy.yml or the VPN action"
fi

echo "== repository hygiene"
# The repository is public: no private addresses and no credentials in the chart, tests or docs.
if grep -rnE '\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b' \
     charts tests docs examples "${new_workflows[@]}" >"$WORK/addr.log"; then
  fail "private network addresses found"; cat "$WORK/addr.log"
else
  pass "no private network addresses in new files"
fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck tests/run.sh; then pass "shellcheck tests/run.sh"; else fail "shellcheck tests/run.sh"; fi
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; exit 1; fi
