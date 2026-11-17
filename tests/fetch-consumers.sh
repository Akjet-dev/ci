#!/usr/bin/env bash
# Fetches the caller workflows and deploy/ directories of the consumers listed in tests/consumers.yaml into
# <target>/<name>, at the branch named there. For runs without a workspace (CI): needs a READ-ONLY token for
# the private application repositories in CONSUMERS_READ_TOKEN (fine-grained PAT or GitHub App token with
# "Contents: read" on exactly those repositories). The token is passed to git through an http header that is
# never written to disk or printed. Nothing is pushed anywhere.
#   tests/fetch-consumers.sh <target directory>
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:?usage: fetch-consumers.sh <target directory>}"
: "${CONSUMERS_READ_TOKEN:?CONSUMERS_READ_TOKEN is not set}"
mkdir -p "${target}"
auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${CONSUMERS_READ_TOKEN}" | base64 | tr -d '\n')"
yq -r '.consumers[] | .name + " " + .repository + " " + .ref' tests/consumers.yaml | while read -r name repository ref; do
  dir="${target}/${name}"
  rm -rf "${dir:?}"
  git -c "http.https://github.com/.extraheader=${auth}" clone --quiet --depth 1 --filter=blob:none --sparse \
    --branch "${ref}" "https://github.com/${repository}.git" "${dir}" 2>/dev/null \
    || { echo "::error::cannot read ${repository}@${ref} (token without access, or the branch does not exist)"; exit 1; }
  git -C "${dir}" -c "http.https://github.com/.extraheader=${auth}" sparse-checkout set --no-cone '/.github/workflows/' '/deploy/' '/Dockerfile*' >/dev/null 2>&1
  echo "fetched ${repository}@${ref} ($(git -C "${dir}" rev-parse --short HEAD))"
done
