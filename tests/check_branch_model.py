#!/usr/bin/env python3
"""Static check of the branch model in a service repository.

Kubernetes workflows (file name k8s-*.yml) must live next to the existing deployment workflows without
ever sharing a trigger with them:

  main, dev/v1, dev/v2, dev/clockster and every
  other existing branch (the prefix dev/ included) -> only the existing workflows, exactly as before
  dev-k8s/release                                  -> K8s build; publishes; the only branch that may
                                                      deploy (DEV)
  stage-k8s/release                                -> K8s build; publishes; never deploys
  every other dev-k8s/*, stage-k8s/*               -> validation, build and scan only

Rules
  B1  a k8s workflow reacts only to push on dev-k8s/** and stage-k8s/**, workflow_dispatch or
      workflow_call - no other events, no branches-ignore, no tags
  B2  a k8s workflow is not triggered by a push to a legacy branch or to an arbitrary branch
  B3  an existing (non-k8s) workflow is not triggered by a push to a Kubernetes branch
  B4  an existing (non-k8s) workflow does not call the Kubernetes reusable workflows
  B5  a job calling deploy-k8s.yml either sets validate-only: true, or targets the literal environment
      "dev" and is guarded by  github.ref == 'refs/heads/dev-k8s/release'  and
      vars.K8S_DEV_DEPLOY_ENABLED == 'true'; it passes only documented inputs
  B6  a k8s workflow uses no legacy deployment credentials, no `secrets: inherit`, and runs its own
      steps only on GitHub-hosted runners (the in-cluster runner is reached only through deploy-k8s.yml)

Usage: check_branch_model.py <directory with workflow files> [--legacy-branch NAME ...]
Requires yq (YAML to JSON). Prints the trigger table and exits 1 on any violation.
"""
import json
import pathlib
import re
import subprocess
import sys

K8S_PUSH_PATTERNS = {"dev-k8s/**", "stage-k8s/**"}
K8S_EVENTS = {"push", "workflow_dispatch", "workflow_call"}
DEPLOY_BRANCH_GUARD = "github.ref == 'refs/heads/dev-k8s/release'"
DEPLOY_SWITCH_GUARD = "vars.K8S_DEV_DEPLOY_ENABLED == 'true'"
DEPLOY_INPUTS = {"environment", "validate-only", "image-digest", "chart-version", "release", "values-dir",
                 "chart", "run-migrations", "restart", "timeout", "pod-logs-on-failure"}
LEGACY_MARKERS = re.compile(r"DEPLOY_SSH_KEY|DEPLOY_PATH|DEPLOY_USER|NETBIRD_|appleboy/ssh-action|/netbird@")
K8S_REUSABLE = re.compile(r"/\.github/workflows/(deploy-k8s|build-image)\.yml@")

DEFAULT_LEGACY_BRANCHES = ["main", "dev/v1"]
K8S_BRANCHES = ["dev-k8s/release", "stage-k8s/release", "dev-k8s/feature-example", "stage-k8s/feature-example"]
# Must never trigger a Kubernetes workflow: the old Kubernetes branch names, the dev/ prefix, look-alikes.
OTHER_BRANCHES = ["feature/example", "fix/example", "dev/k8s", "stage/k8s", "dev/feature-example",
                  "dev/other", "stage/other", "dev/v2", "dev/clockster", "dev-k8s", "stage-k8s",
                  "dev-k8s-copy", "stage-k8s-copy", "dev-k8s-release", "release/dev-k8s"]


def pattern_to_regex(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(f"^{out}$")


def matches(patterns, branch):
    """GitHub filter semantics: later patterns win, '!' negates."""
    result = False
    for pattern in patterns:
        negate = pattern.startswith("!")
        if pattern_to_regex(pattern[1:] if negate else pattern).match(branch):
            result = not negate
    return result


def events(workflow):
    on = workflow.get("on")
    if isinstance(on, str):
        return {on: {}}
    if isinstance(on, list):
        return {name: {} for name in on}
    return {name: (cfg or {}) for name, cfg in (on or {}).items()}


def push_triggers(workflow, branch):
    cfg = events(workflow).get("push")
    if cfg is None:
        return False
    if "branches" in cfg:
        return matches(cfg["branches"], branch)
    if "branches-ignore" in cfg:
        return not matches(cfg["branches-ignore"], branch)
    return "tags" not in cfg or "branches" in cfg  # no branch filter: every branch


def check(workflows, legacy_branches):
    errs = []
    for name, (wf, text) in workflows.items():
        is_k8s = name.startswith("k8s-")
        evs = events(wf)
        if is_k8s:
            extra = set(evs) - K8S_EVENTS
            if extra:
                errs.append(f"B1 {name}: events {sorted(extra)} are not allowed in a Kubernetes workflow")
            push = evs.get("push")
            if push is not None:
                patterns = set(push.get("branches") or [])
                if not patterns or patterns - K8S_PUSH_PATTERNS or set(push) - {"branches", "paths", "paths-ignore"}:
                    errs.append(f"B1 {name}: push must list only {sorted(K8S_PUSH_PATTERNS)} "
                                f"(found {push})")
            for branch in legacy_branches + OTHER_BRANCHES:
                if push_triggers(wf, branch):
                    errs.append(f"B2 {name}: is triggered by a push to {branch}")
            if LEGACY_MARKERS.search(text):
                errs.append(f"B6 {name}: uses legacy deployment credentials or actions")
            for job_id, job in (wf.get("jobs") or {}).items():
                ref = f"{name}:{job_id}"
                if job.get("secrets") == "inherit":
                    errs.append(f"B6 {ref}: secrets: inherit")
                uses = job.get("uses") or ""
                if not uses:
                    runs_on = job.get("runs-on")
                    if not isinstance(runs_on, str) or not runs_on.startswith("ubuntu-"):
                        errs.append(f"B6 {ref}: own steps must run on a GitHub-hosted runner (runs-on: {runs_on!r})")
                if "/deploy-k8s.yml@" in uses:
                    params = job.get("with") or {}
                    unknown = set(params) - DEPLOY_INPUTS
                    if unknown:
                        errs.append(f"B5 {ref}: unknown inputs {sorted(unknown)}")
                    if params.get("validate-only") is True:
                        continue
                    condition = str(job.get("if") or "")
                    if params.get("environment") != "dev":
                        errs.append(f"B5 {ref}: a deploying job must target the literal environment 'dev' "
                                    f"(found {params.get('environment')!r})")
                    if DEPLOY_BRANCH_GUARD not in condition:
                        errs.append(f"B5 {ref}: missing guard  if: {DEPLOY_BRANCH_GUARD}")
                    if DEPLOY_SWITCH_GUARD not in condition:
                        errs.append(f"B5 {ref}: missing guard  if: {DEPLOY_SWITCH_GUARD}")
                    if "||" in condition:
                        errs.append(f"B5 {ref}: the deployment guard must not contain '||'")
        else:
            for branch in K8S_BRANCHES:
                if push_triggers(wf, branch):
                    errs.append(f"B3 {name}: existing workflow is triggered by a push to {branch}")
            if K8S_REUSABLE.search(text):
                errs.append(f"B4 {name}: existing workflow calls a Kubernetes reusable workflow")
    return errs


def load(directory):
    workflows = {}
    for path in sorted(pathlib.Path(directory).glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        data = json.loads(subprocess.run(["yq", "-o=json", ".", str(path)], check=True,
                                         capture_output=True, text=True).stdout)
        workflows[path.name] = (data or {}, text)
    return workflows


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    legacy = list(DEFAULT_LEGACY_BRANCHES)
    for i, arg in enumerate(argv):
        if arg == "--legacy-branch":
            legacy.append(argv[i + 1])
    workflows = load(argv[1])
    if not workflows:
        print(f"branch-model: no workflow files in {argv[1]}")
        return 0
    branches = legacy + K8S_BRANCHES + ["dev/k8s", "feature/example"]
    print(f"branch-model: push triggers in {argv[1]}")
    for branch in branches:
        hit = [name for name, (wf, _) in workflows.items() if push_triggers(wf, branch)]
        print(f"  {branch:<26} -> {', '.join(hit) if hit else '-'}")
    errs = check(workflows, legacy)
    for err in errs:
        print(f"branch-model: {err}", file=sys.stderr)
    if not errs:
        print("branch-model: ok")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
