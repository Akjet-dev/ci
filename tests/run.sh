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
if out "namespace=dev-example-api" && out "runner=akjet-ds-apps" && out "release=example-api" \
   && out "chart=oci://ghcr.io/example-org/charts/akjet-app"; then
  pass "namespace is derived from the repository (dev-example-api); runner is the shared akjet-ds-apps"
else
  fail "derived target"; cat "$WORK/gh_output"
fi
accept "the runner label does not depend on the repository" "runner=akjet-ds-apps" dev refs/heads/dev-k8s/release push false "$good_digest" "" deploy "" Example-Org/other-service
accept "manual run on dev-k8s/release deploys to dev" "deploy=true" dev refs/heads/dev-k8s/release workflow_dispatch false
accept "another release name stays in the same namespace" "namespace=dev-example-api" dev refs/heads/dev-k8s/release push false "$good_digest" satellite
accept "other dev-k8s/* branch: validation only, no deployment" "deploy=false" dev refs/heads/dev-k8s/feature-x push true ""
accept "stage-k8s/release: stage values are validated, no deployment" "deploy=false" stage refs/heads/stage-k8s/release push true ""
if out "namespace=stage-example-api"; then pass "stage validation renders for namespace stage-example-api"; else fail "stage namespace"; fi

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
reject "release with shell metacharacters" dev refs/heads/dev-k8s/release push false "$good_digest" 'x;id'
reject "values-dir outside the repository" dev refs/heads/dev-k8s/release push false "$good_digest" "" ../other
reject "chart from an arbitrary URL" dev refs/heads/dev-k8s/release push false "$good_digest" "" deploy https://example.test/chart.tgz
reject "repository name unusable as namespace" dev refs/heads/dev-k8s/release push false "$good_digest" "" deploy "" Example-Org/Example_API

echo "== deploy-k8s.yml: namespaces shared by several repositories"
rel=(dev refs/heads/dev-k8s/release push false "$good_digest")
accept "backend deploys to the shared namespace dev-lk-backend" "namespace=dev-lk-backend" "${rel[@]}" "" deploy "" Akjet-dev/backend
if out "release=backend"; then pass "backend keeps its own release name"; else fail "release of backend"; cat "$WORK/gh_output"; fi
accept "lk-frontend deploys to the same namespace dev-lk-backend" "namespace=dev-lk-backend" "${rel[@]}" "" deploy "" Akjet-dev/lk-frontend
if out "release=lk-frontend"; then pass "lk-frontend keeps its own release name"; else fail "release of lk-frontend"; cat "$WORK/gh_output"; fi
accept "backend: stage values are validated for stage-lk-backend" "namespace=stage-lk-backend" stage refs/heads/stage-k8s/release push true "" "" deploy "" Akjet-dev/backend
accept "lk-frontend: stage values are validated for stage-lk-backend" "namespace=stage-lk-backend" stage refs/heads/stage-k8s/release push true "" "" deploy "" Akjet-dev/lk-frontend
accept "shared namespace: a second release of the same repository is allowed" "release=backend-tools" "${rel[@]}" backend-tools deploy "" Akjet-dev/backend
reject "shared namespace: lk-frontend cannot manage the release 'backend'" "${rel[@]}" backend deploy "" Akjet-dev/lk-frontend
reject "shared namespace: backend cannot manage the release 'lk-frontend'" "${rel[@]}" lk-frontend deploy "" Akjet-dev/backend
reject "shared namespace: backend cannot manage an arbitrary release name" "${rel[@]}" satellite deploy "" Akjet-dev/backend
for other in executor-frontend landing bcc-kommo-api; do
  accept "$other keeps its own namespace dev-$other" "namespace=dev-$other" "${rel[@]}" "" deploy "" "Akjet-dev/$other"
  accept "$other keeps its own namespace stage-$other" "namespace=stage-$other" stage refs/heads/stage-k8s/release push true "" "" deploy "" "Akjet-dev/$other"
done
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
mkdir -p "$WORK/src" && : >"$WORK/src/Dockerfile"
push_decision() {  # ref-name ref-type push-input
  : >"$WORK/gh_output"
  ( cd "$WORK/src" && env -i PATH="$PATH" GITHUB_OUTPUT="$WORK/gh_output" GITHUB_REPOSITORY="Example-Org/example-api" \
      GITHUB_REPOSITORY_OWNER="Example-Org" PUBLISH_BRANCHES="$publish_branches" GITHUB_REF_NAME="$1" GITHUB_REF_TYPE="$2" \
      IMAGE_INPUT="" CONTEXT="." DOCKERFILE="Dockerfile" PLATFORM="linux/amd64" PUSH_INPUT="$3" SCAN_FAIL_ON="CRITICAL" \
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
if out "image=ghcr.io/example-org/example-api" || { push_decision dev-k8s/release branch true >/dev/null; out "image=ghcr.io/example-org/example-api"; }; then
  pass "image name is derived from the repository: ghcr.io/example-org/example-api"
else
  fail "image name"
fi
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
if [ "$uses_overrides" = "3" ] && [ "$(grep -c -- '-f "${VALUES_DIR}/values.yaml" -f "${VALUES_DIR}/values-${ENVIRONMENT}.yaml"' "$dk")" = "3" ]; then
  pass "validation render, migration render and helm upgrade all load values.yaml, values-<env>.yaml, then the overrides ($uses_values steps)"
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
    name="$5"; test -f "$FAKE_STATE/$name.rv" || { echo "Error from server (NotFound)" >&2; exit 1; }
    cat "$FAKE_STATE/$name.rv" ;;
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
if grep -q 'create' <<<"$sec_step" && ! grep -qE 'kubectl[^|]* create|can-i "?create' <<<"$sec_step"; then
  pass "the Secret step never creates Secret objects"
else
  fail "the Secret step must not create Secret objects"
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
if syn_check; then fail "not detected: namespace drift between the workflow and the platform"
elif grep -qF "resolves dev to namespace dev-example-api, the platform expects dev-other" "$WORK/syn.log"; then pass "detected: the namespace the candidate resolves differs from what the platform provides"
else fail "namespace drift detected for another reason"; fi
yq -i '.consumers[0].namespace.dev = "dev-example-api"' "$syn/manifest.yaml"
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
