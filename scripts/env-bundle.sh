#!/usr/bin/env bash
# Operator tool for the environment bundle of a service (secret env-bundle of deploy-k8s.yml).
# It runs the SAME step the workflow runs ("Check the environment bundle"), taken from the workflow file
# next to this script - there is no second implementation that could drift.
#
#   env-bundle.sh check    <environment> <bundle.json> [values-dir]   validate; prints NAMES only, never values
#   env-bundle.sh template <environment> [values-dir]                 print a bundle skeleton (empty values)
#
# Pass-through services (input env-bundle-secret of deploy-k8s.yml): the Secret name is read from the caller
# workflows of the current repository (.github/workflows/*.yml); ENV_BUNDLE_SECRET=<name> overrides it,
# ENV_BUNDLE_SECRET= (empty) forces the declared mode.
# <environment>: any environment that has <values-dir>/values-<environment>.yaml (dev, stage, ...).
# [values-dir]:  default ./deploy (run from the service repository).
# Needs: bash, yq (mikefarah v4), jq. Nothing is sent anywhere and nothing is written next to the bundle.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
workflow="${here}/../.github/workflows/deploy-k8s.yml"
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
command="$1"; environment="$2"
for tool in yq jq; do command -v "${tool}" >/dev/null || { echo "${tool} is required" >&2; exit 2; }; done
step="$(yq '.jobs.validate.steps[] | select(.id == "bundle") | .run' "${workflow}")"
[ -n "${step}" ] || { echo "step 'bundle' not found in ${workflow}" >&2; exit 2; }
if [ -n "${ENV_BUNDLE_SECRET+set}" ]; then
  bundle_secret="${ENV_BUNDLE_SECRET}"
else
  bundle_secret="$(cat .github/workflows/*.yml 2>/dev/null | grep -E '^[[:space:]]*env-bundle-secret:' | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d "\"'" || true)"
fi
[ -z "${bundle_secret}" ] || echo "pass-through mode: every key goes to Secret '${bundle_secret}' (env-bundle-secret)" >&2
work="$(mktemp -d "${TMPDIR:-/tmp}/env-bundle.XXXXXX")"; trap 'rm -rf "${work:?}"' EXIT
case "${command}" in
  check)
    [ $# -ge 3 ] || usage
    file="$3"; values="${4:-deploy}"
    [ -f "${file}" ] || { echo "no such file: ${file}" >&2; exit 2; }
    ENV_BUNDLE="$(cat "${file}")" ENVIRONMENT="${environment}" VALUES_DIR="${values}" BUNDLE_MODE=check BUNDLE_SECRET="${bundle_secret}" \
      RUNNER_TEMP="${work}" GITHUB_OUTPUT="${work}/output" bash --noprofile --norc -c "${step}" </dev/null \
      | sed 's/^::error::/ERROR: /; s/^::warning::/WARNING: /'
    ;;
  template)
    values="${3:-deploy}"
    ENV_BUNDLE='' ENVIRONMENT="${environment}" VALUES_DIR="${values}" BUNDLE_MODE=template BUNDLE_SECRET="" \
      RUNNER_TEMP="${work}" GITHUB_OUTPUT="${work}/output" bash --noprofile --norc -c "${step}" </dev/null \
      | sed 's/^::error::/ERROR: /'
    ;;
  *) usage ;;
esac
