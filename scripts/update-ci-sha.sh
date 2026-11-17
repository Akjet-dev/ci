#!/usr/bin/env bash
# Points every consumer of the shared workflows at ONE published revision of Akjet-dev/ci.
#
#   scripts/update-ci-sha.sh <full commit SHA> [--apply] [--workspace DIR]
#
# Default is a dry run: it verifies the revision and prints the diff it WOULD make. --apply edits the
# working trees and prints `git diff`. It never commits, pushes, deploys or touches anything but
#   <workspace>/<consumer>/.github/workflows/k8s-*.yml   lines   uses: Akjet-dev/ci/.github/workflows/<file>@<sha>
# Other action references (actions/checkout, Akjet-dev/ci/netbird, ...) and other files are left alone.
#
# Checks before anything is changed:
#   1. the argument is a full 40-character commit SHA, not a branch, tag or the zero placeholder
#   2. the commit is part of origin/main of this repository (fetched first) - i.e. published and merged
#   3. the reusable workflows exist at that revision
#   4. every consumer is compatible with the workflows OF THAT REVISION (tests/check_consumers.py from it)
# Consumers: tests/consumers.yaml. Workspace: the directory that holds ci and the consumers (default: ..).
set -euo pipefail
cd "$(dirname "$0")/.."
sha="${1:-}"; shift || true
apply=false; workspace=".."
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=true ;;
    --workspace) workspace="${2:?--workspace needs a directory}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
die() { echo "ERROR: $1" >&2; exit 1; }
printf '%s' "${sha}" | grep -Eq '^[0-9a-f]{40}$' || die "give the full 40-character commit SHA of Akjet-dev/ci (got '${sha}')"
[ "${sha}" != "0000000000000000000000000000000000000000" ] || die "the zero placeholder is not a revision"
git fetch --quiet origin main 2>/dev/null || echo "note: could not fetch origin; using the local copy of origin/main"
git cat-file -e "${sha}^{commit}" 2>/dev/null || die "${sha} is not a commit of this repository (not published, or not fetched)"
git merge-base --is-ancestor "${sha}" origin/main || die "${sha} is not part of origin/main: publish and merge it first"
for f in deploy-k8s.yml build-image.yml; do
  git cat-file -e "${sha}:.github/workflows/${f}" 2>/dev/null || die "${f} does not exist at ${sha}"
done
echo "revision ${sha}: on origin/main, reusable workflows present"

work="$(mktemp -d "${TMPDIR:-/tmp}/ci-sha.XXXXXX")"; trap 'rm -rf "${work:?}"' EXIT
# Compatibility is judged by the workflows and the checker OF THE TARGET REVISION, not of the working tree.
mkdir -p "${work}/ci"
git archive "${sha}" | tar -x -C "${work}/ci"
if [ -f "${work}/ci/tests/check_consumers.py" ]; then
  python3 "${work}/ci/tests/check_consumers.py" --workspace "${workspace}" >"${work}/check.log" 2>&1 \
    || { grep -E 'ERROR|^consumers' "${work}/check.log" >&2; die "a consumer is not compatible with ${sha}; nothing was changed"; }
  echo "every consumer is compatible with the workflows of ${sha} (static contract check)"
else
  die "${sha} has no tests/check_consumers.py: compatibility with that revision cannot be verified"
fi

changed=0
for name in $(yq -r '.consumers[].name' tests/consumers.yaml); do
  repo="${workspace}/${name}"
  [ -d "${repo}/.github/workflows" ] || { echo "skip ${name}: ${repo} not found"; continue; }
  for file in "${repo}"/.github/workflows/k8s-*.yml; do
    [ -f "${file}" ] || continue
    sed -E "s#(uses:[[:space:]]*Akjet-dev/ci/\.github/workflows/(deploy-k8s|build-image)\.yml@)[0-9a-f]{40}#\1${sha}#" "${file}" >"${work}/new"
    if ! cmp -s "${file}" "${work}/new"; then
      changed=$((changed + 1))
      if ${apply}; then
        cat "${work}/new" >"${file}"
      else
        diff -u "${file}" "${work}/new" | sed "1s#.*#--- ${name}/.github/workflows/$(basename "${file}")#; 2s#.*#+++ (after)#" || true
      fi
    fi
  done
  if ${apply}; then git -C "${repo}" --no-pager diff -- .github/workflows; fi
done
if ${apply}; then
  python3 "${work}/ci/tests/check_consumers.py" --workspace "${workspace}" --expect-sha "${sha}" --strict-sha | grep -E '^  (consumer|[a-z].* (OK|error))|ERROR|K10' || true
  echo "${changed} file(s) updated. Nothing was committed or pushed: review the diffs above, then commit per repository."
else
  echo "dry run: ${changed} file(s) would change. Re-run with --apply to edit the working trees."
fi
