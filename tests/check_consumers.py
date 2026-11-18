#!/usr/bin/env python3
"""Contract check between the reusable workflows of this repository and their consumers.

The CANDIDATE is always the tree this script lives in (never a published revision): every consumer is
validated against .github/workflows/{deploy-k8s,build-image}.yml as they are on disk right now.

Consumers are listed in tests/consumers.yaml. Their caller workflows are read
  - from a workspace (--workspace DIR: sibling checkouts DIR/<name>), when available - the real files; or
  - from tests/consumers/<name>.json - a small snapshot of the calls (NOT a copy of the workflows), written
    by --write-snapshots from the real files. In a workspace the snapshot is also checked for being current.

Rules (static: nothing is executed on GitHub, nothing is deployed)
  K1  every `uses: Akjet-dev/ci/.github/workflows/<file>@<ref>` names a reusable workflow that exists and is
      pinned to a full commit SHA; the all-zero placeholder is reported as PENDING (an error with --strict-sha)
  K2  `with`: only declared inputs, every required input, literal values of the declared type
  K3  `secrets`: only declared secrets, every required secret, never `secrets: inherit`
  K4  outputs read by the caller (needs.<job>.outputs.<name>) exist in the called workflow
  K5  the calling job grants at least the token permissions the called workflow's jobs ask for
  K6  runtime secrets (app-secrets, env-bundle) are passed only by a deploying call, never together, and
      never from a repository secret of another environment
  K7  a call of a local reusable workflow (./.github/workflows/x.yml) matches that file's own interface
  K8  chart-version equals the version of charts/akjet-app
  K9  the namespace and release come from the consumer's own values (deployment.*), resolved by the
      candidate's identity step; the namespace is the one the platform provides (tests/consumers.yaml)
  K11 consumers that share a namespace declare different releases
  K12 the image is declared in the values (image.repository under ghcr.io/<owner>/); a build call that
      still passes the deprecated `image` input names the same image
  K10 every consumer pins the same revision (reported; an error with --expect-sha / --strict-sha)
With a workspace, additionally (H = Helm, D = Docker build contract, O = opt-in behaviour):
  H1  values of dev and stage: helm lint, helm template, kubeconform, security policy, allowed kinds
  D1  the Dockerfile the build is called with exists; BuildKit secret ids match the build-secrets passed
  O1  without env-bundle / app-secrets / repository variables the optional steps of the candidate finish
      successfully and do nothing

Usage
  check_consumers.py [--workspace DIR] [--write-snapshots] [--expect-sha SHA] [--strict-sha]
                     [--against-pinned] [--fail-on-stale-snapshot] [--report FILE]
                     [--manifest FILE] [--snapshots DIR]
Requires yq; helm, kubeconform and jq for the H/O rules (skipped with a note when missing).
"""
import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
REUSABLE = ("deploy-k8s.yml", "build-image.yml")
USES = re.compile(r"^Akjet-dev/ci/\.github/workflows/([A-Za-z0-9_.-]+)@(.+)$")
SHA = re.compile(r"^[0-9a-f]{40}$")
ZERO = "0" * 40
EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)
LEVEL = {None: 0, "none": 0, "read": 1, "write": 2}
RUNTIME_SECRETS = ("app-secrets", "env-bundle")


def yq_json(path=None, text=None):
    cmd = ["yq", "-o=json", "."] + ([str(path)] if path else [])
    out = subprocess.run(cmd, input=text, check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else {}


def interface(doc):
    """workflow_call interface of a parsed workflow."""
    on = doc.get("on") or {}
    call = (on.get("workflow_call") if isinstance(on, dict) else None) or {}
    inputs = {k: {"type": (v or {}).get("type", "string"), "required": bool((v or {}).get("required")),
                  "default": (v or {}).get("default")} for k, v in (call.get("inputs") or {}).items()}
    secrets = {k: bool((v or {}).get("required")) for k, v in (call.get("secrets") or {}).items()}
    need = {}
    for job in (doc.get("jobs") or {}).values():
        for scope, level in ((job.get("permissions") or doc.get("permissions") or {}) or {}).items():
            if LEVEL.get(level, 0) > LEVEL.get(need.get(scope), 0):
                need[scope] = level
    return {"inputs": inputs, "secrets": secrets, "outputs": sorted((call.get("outputs") or {}).keys()),
            "permissions": need, "is_reusable": "workflow_call" in on if isinstance(on, dict) else False}


def candidate_interfaces(root):
    return {f: interface(yq_json(root / ".github/workflows" / f)) for f in REUSABLE}


def literal(value):
    return not (isinstance(value, str) and EXPR.search(value))


def values_identity(repo_dir):
    """deployment.* per environment and image.repository, read from the values files (no other values)."""
    deploy = pathlib.Path(repo_dir) / "deploy"
    out = {"deployment": {}, "image": None}
    if not (deploy / "values.yaml").exists():
        return out
    out["image"] = yq_json(deploy / "values.yaml").get("image", {}).get("repository")
    for env in ("dev", "stage"):
        files = [str(deploy / "values.yaml")] + ([str(deploy / f"values-{env}.yaml")] if (deploy / f"values-{env}.yaml").exists() else [])
        merged = subprocess.run(["yq", "ea", "-o=json", ". as $d ireduce ({}; . * $d) | .deployment // {}"] + files,
                                check=True, capture_output=True, text=True).stdout
        out["deployment"][env] = json.loads(merged or "{}")
    return out


def extract(repo_dir):
    """Snapshot of the calls of one consumer: what it passes to which workflow, and its deployment identity
    from the values. No workflow bodies, no other values."""
    wf_dir = pathlib.Path(repo_dir) / ".github/workflows"
    snap = {"workflows": {}, "values": values_identity(repo_dir)}
    for path in sorted(wf_dir.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        doc = yq_json(path)
        calls = []
        for job_id, job in (doc.get("jobs") or {}).items():
            uses = job.get("uses") or ""
            if not uses:
                continue
            m = USES.match(uses)
            if not m and not uses.startswith("./"):
                continue
            perms = job.get("permissions") if job.get("permissions") is not None else doc.get("permissions")
            calls.append({
                "job": job_id,
                "uses": m.group(1) if m else uses,
                "ref": m.group(2) if m else None,
                "with": job.get("with") or {},
                "secrets": job.get("secrets") if job.get("secrets") is not None else {},
                "permissions": perms,
                "if": job.get("if"),
                "outputs_read": sorted(set(re.findall(r"needs\.%s\.outputs\.([A-Za-z0-9_-]+)" % re.escape(job_id), text))),
            })
        if not calls and not path.name.startswith("k8s-"):
            continue
        own = interface(doc)
        snap["workflows"][path.name] = {
            "interface": {"inputs": own["inputs"], "secrets": own["secrets"]} if own["is_reusable"] else None,
            "calls": calls,
        }
    return snap


def without_refs(snap):
    """A snapshot is stale when the calls or the deployment identity changed, not when a consumer merely moved
    to another revision."""
    snap.setdefault("values", None)
    for wf in snap["workflows"].values():
        for call in wf["calls"]:
            call["ref"] = None if call["ref"] is None else "pinned"
    return snap


def check_call(where, call, iface, errs):
    params = call["with"] or {}
    for name in sorted(set(params) - set(iface["inputs"])):
        errs.append(f"K2 {where}: input '{name}' is not defined in the referenced workflow")
    for name, spec in iface["inputs"].items():
        if spec["required"] and name not in params:
            errs.append(f"K2 {where}: required input '{name}' is missing")
        if name in params and literal(params[name]):
            value, kind = params[name], spec["type"]
            ok = {"boolean": isinstance(value, bool), "number": isinstance(value, (int, float)) and not isinstance(value, bool),
                  "string": isinstance(value, (str, int, float)) and not isinstance(value, bool)}.get(kind, True)
            if not ok:
                errs.append(f"K2 {where}: input '{name}' must be {kind}, got {value!r}")
    secrets = call["secrets"]
    if secrets == "inherit":
        errs.append(f"K3 {where}: secrets: inherit - every secret must be passed by name")
        secrets = {}
    for name in sorted(set(secrets or {}) - set(iface["secrets"])):
        errs.append(f"K3 {where}: Invalid secret, {name} is not defined in the referenced workflow")
    for name, required in iface["secrets"].items():
        if required and name not in (secrets or {}):
            errs.append(f"K3 {where}: required secret '{name}' is missing")
    for name in call.get("outputs_read") or []:
        if name not in iface.get("outputs", []):
            errs.append(f"K4 {where}: output '{name}' is not defined in the referenced workflow")
    have = call.get("permissions")
    if isinstance(have, dict):
        for scope, level in (iface.get("permissions") or {}).items():
            if LEVEL.get(have.get(scope), 0) < LEVEL[level]:
                errs.append(f"K5 {where}: the job grants {scope}: {have.get(scope) or 'none'}, the referenced workflow needs {scope}: {level}")
    elif iface.get("permissions"):
        errs.append(f"K5 {where}: no permissions block (job or workflow level); the referenced workflow needs {iface['permissions']}")


def check_consumer(consumer, snap, ifaces, chart_version, errs, notes):
    name = consumer["name"]
    refs = set()
    for wf_name, wf in snap["workflows"].items():
        for call in wf["calls"]:
            where = f"{name}/{wf_name}:{call['job']}"
            if call["ref"] is None:  # local reusable workflow
                target = snap["workflows"].get(pathlib.PurePosixPath(call["uses"]).name)
                if not target or not target["interface"]:
                    errs.append(f"K7 {where}: {call['uses']} is not a reusable workflow of the repository")
                    continue
                local = dict(target["interface"], outputs=[], permissions={})
                before = len(errs)
                check_call(where, dict(call, outputs_read=[]), local, errs)
                errs[before:] = [e.replace("K2 ", "K7 ").replace("K3 ", "K7 ") for e in errs[before:]]
                continue
            if call["uses"] not in ifaces:
                errs.append(f"K1 {where}: Akjet-dev/ci has no reusable workflow {call['uses']}")
                continue
            refs.add(call["ref"])
            if call["ref"] == ZERO:
                notes.append(f"PENDING {where}: placeholder revision (40 zeros) - substitute the published SHA")
            elif not SHA.match(call["ref"]):
                errs.append(f"K1 {where}: '{call['ref']}' is not a full commit SHA (branches and tags are mutable)")
            check_call(where, call, ifaces[call["uses"]], errs)
            if call["uses"] == "deploy-k8s.yml":
                params, secrets = call["with"] or {}, call["secrets"] if isinstance(call["secrets"], dict) else {}
                passed = [s for s in RUNTIME_SECRETS if s in secrets]
                if passed and params.get("validate-only") is True:
                    errs.append(f"K6 {where}: {', '.join(passed)} passed to a validate-only call")
                if len(passed) > 1:
                    errs.append(f"K6 {where}: app-secrets and env-bundle are passed together")
                env = params.get("environment")
                if passed and env != "dev":
                    errs.append(f"K6 {where}: runtime secrets are passed, but the environment is not the literal 'dev'")
                for s in passed:
                    foreign = sorted(set(re.findall(r"secrets\.((?:STAGE|PROD|PRODUCTION)_[A-Za-z0-9_]+)", str(secrets[s]))))
                    if foreign:
                        errs.append(f"K6 {where}: {s} reads secrets of another environment: {', '.join(foreign)}")
                if "chart-version" in params and literal(params["chart-version"]) and str(params["chart-version"]) != chart_version:
                    errs.append(f"K8 {where}: chart-version {params['chart-version']} != charts/akjet-app {chart_version}")
    return refs


def resolve_identity(workflow_file, snap, environment):
    """Runs the real identity step of a deploy-k8s.yml on the consumer's deployment block.
    Returns (outputs, error); outputs is None when the revision has no identity step."""
    step = subprocess.run(["yq", '.jobs.validate.steps[] | select(.id == "identity") | .run', str(workflow_file)],
                          check=True, capture_output=True, text=True).stdout.strip()
    if not step:
        return None, None
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / "deploy").mkdir()
        meta = (snap.get("values") or {}).get("deployment", {}).get(environment, {})
        (tmp / "deploy/values.yaml").write_text(json.dumps({"deployment": meta}) + "\n")
        (tmp / f"deploy/values-{environment}.yaml").write_text("{}\n")
        out = tmp / "out"
        out.write_text("")
        env = {"PATH": os.environ["PATH"], "RUNNER_TEMP": str(tmp / "rt"), "GITHUB_OUTPUT": str(out), "ENVIRONMENT": environment,
               "VALUES_DIR": "deploy", "TIMEOUT": "10m", "RELEASE_INPUT": "", "BUNDLE_SECRET_INPUT": ""}
        run = subprocess.run(["bash", "--noprofile", "--norc", "-c", step], env=env, cwd=tmp, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if run.returncode != 0:
            msg = [l for l in (run.stdout + run.stderr).splitlines() if l.startswith("::error::")]
            return {}, (msg[-1][9:] if msg else "the identity step failed")
        return dict(l.split("=", 1) for l in out.read_text().splitlines() if "=" in l), None


def resolve_namespace(workflow_file, repository, environment):
    """Legacy revisions (namespace derived from the repository): runs their 'Resolve and check the target' step."""
    step = subprocess.run(["yq", ".jobs.validate.steps[0].run", str(workflow_file)], check=True, capture_output=True, text=True).stdout
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "out"
        out.write_text("")
        env = {"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(out), "GITHUB_REPOSITORY": repository,
               "GITHUB_REPOSITORY_OWNER": repository.split("/")[0], "RUNNER_LABEL": "akjet-ds-apps",
               "DEV_DEPLOY_BRANCH": "dev-k8s/release", "ENVIRONMENT": environment, "GITHUB_REF": "refs/heads/dev-k8s/check",
               "GITHUB_EVENT_NAME": "push", "VALIDATE_ONLY": "true", "DIGEST": "", "RELEASE_INPUT": "", "VALUES_DIR": "deploy",
               "CHART_INPUT": "", "CHART_VERSION": "0.1.0", "TIMEOUT": "10m", "DEPLOY_ENABLED": ""}
        run = subprocess.run(["bash", "--noprofile", "--norc", "-c", step], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if run.returncode != 0:
            return None
        return dict(l.split("=", 1) for l in out.read_text().splitlines() if "=" in l).get("namespace")


def run_step(workflow_file, selector, env, cwd):
    step = subprocess.run(["yq", selector, str(workflow_file)], check=True, capture_output=True, text=True).stdout
    return subprocess.run(["bash", "--noprofile", "--norc", "-c", step], env=dict({"PATH": os.environ["PATH"]}, **env), cwd=cwd,
                          stdin=subprocess.DEVNULL, capture_output=True, text=True)


def check_repo(consumer, repo, snap, root, errs, notes, skipped, identity):
    """Rules that need the files of the consumer: Helm values, Docker build contract, opt-in behaviour."""
    name = consumer["name"]
    dk = root / ".github/workflows/deploy-k8s.yml"
    have = {t: shutil.which(t) for t in ("helm", "kubeconform", "jq")}
    schema_dir = os.environ.get("SCHEMA_DIR")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        for env in ("dev", "stage"):
            values = [repo / "deploy/values.yaml", repo / f"deploy/values-{env}.yaml"]
            if not all(v.exists() for v in values):
                errs.append(f"H1 {name}: deploy/values.yaml or deploy/values-{env}.yaml is missing")
                continue
            # O1: optional steps without bundle, explicit secrets or variables
            if have["jq"]:
                base = {"RUNNER_TEMP": str(tmp), "GITHUB_OUTPUT": str(tmp / "out"), "GITHUB_STEP_SUMMARY": str(tmp / "summary"),
                        "ENVIRONMENT": env, "VALUES_DIR": "deploy"}
                (tmp / "out").write_text("")
                for label, selector, extra in (
                        ("declared Secret keys", '.jobs.validate.steps[] | select(.id == "declared") | .run', {}),
                        ("environment bundle (absent)", '.jobs.validate.steps[] | select(.id == "bundle") | .run', {"ENV_BUNDLE": ""}),
                        ("variable overrides (no variables)", '.jobs.validate.steps[] | select(.id == "overrides") | .run', {"REPOSITORY_VARIABLES": "{}"})):
                    r = run_step(dk, selector, dict(base, **extra), repo)
                    if r.returncode != 0:
                        errs.append(f"O1 {name} ({env}): step '{label}' fails without optional inputs: {(r.stdout + r.stderr).strip().splitlines()[-1:]}")
                outputs = dict(l.split("=", 1) for l in (tmp / "out").read_text().splitlines() if "=" in l)
                if outputs.get("plan", ""):
                    errs.append(f"O1 {name} ({env}): a Secret plan was produced without a bundle")
                if json.loads(outputs.get("json", "{}") or "{}") != {}:
                    errs.append(f"O1 {name} ({env}): overrides were produced without variables")
                # the deploy-side Secret step must not touch the cluster when nothing was passed
                fake = tmp / "bin"
                fake.mkdir(exist_ok=True)
                (fake / "kubectl").write_text("#!/bin/sh\necho called >> \"$FAKE_LOG\"\nexit 1\n")
                (fake / "kubectl").chmod(0o755)
                r = run_step(dk, '.jobs.deploy.steps[] | select(.id == "secrets") | .run',
                             {"PATH": f"{fake}:{os.environ['PATH']}", "FAKE_LOG": str(tmp / "kubectl.log"), "RUNNER_TEMP": str(tmp),
                              "GITHUB_OUTPUT": str(tmp / "sec"), "NAMESPACE": "x", "RELEASE": name, "VALUES_DIR": "deploy", "ENVIRONMENT": "dev",
                              "APP_SECRETS": "", "ENV_BUNDLE": "", "DECLARED": outputs.get("list", ""), "PLAN": ""}, repo)
                if r.returncode != 0 or (tmp / "kubectl.log").exists() or "changed=false" not in (tmp / "sec").read_text():
                    errs.append(f"O1 {name} ({env}): Secret provisioning is not a no-op without app-secrets / env-bundle")
            else:
                skipped.add("O1 (jq not installed)")
            # H1
            if not have["helm"]:
                skipped.add("H1 (helm not installed)")
                continue
            # Helm gets the values without `deployment`, exactly as the workflow hands them over.
            stripped = []
            for v in values:
                target = tmp / f"helm-{env}-{v.name}"
                target.write_text(subprocess.run(["yq", "del(.deployment)", str(v)], check=True, capture_output=True, text=True).stdout)
                stripped.append(target)
            common = ["-f", str(stripped[0]), "-f", str(stripped[1]), "--set-string", "image.digest=sha256:" + "0" * 64]
            chart = str(root / "charts/akjet-app")
            lint = subprocess.run(["helm", "lint", chart] + common, capture_output=True, text=True)
            if lint.returncode != 0:
                errs.append(f"H1 {name} ({env}): helm lint failed: {lint.stdout.strip().splitlines()[-3:]}")
                continue
            ident = identity.get(env) or {}
            if not ident.get("namespace") or not ident.get("release"):
                skipped.add(f"H1 {name} ({env}): no valid deployment identity (see K9)")
                continue
            rendered = tmp / f"{name}-{env}.yaml"
            tpl = subprocess.run(["helm", "template", ident["release"], chart, "--namespace", ident["namespace"]] + common, capture_output=True, text=True)
            if tpl.returncode != 0:
                errs.append(f"H1 {name} ({env}): helm template failed: {tpl.stderr.strip().splitlines()[-2:]}")
                continue
            rendered.write_text(tpl.stdout)
            objects = subprocess.run(["yq", "ea", "-o=json", "[.]", str(rendered)], check=True, capture_output=True, text=True).stdout
            kinds = sorted({o["kind"] for o in json.loads(objects) if o})
            bad = [k for k in kinds if k not in ("ConfigMap", "ServiceAccount", "Deployment", "Service", "Job")]
            if bad:
                errs.append(f"H1 {name} ({env}): kinds {bad} must not be deployed by an application release")
            policy = subprocess.run([sys.executable, str(root / "tests/policy_check.py"), "--name", f"{name}-{env}"], input=objects, capture_output=True, text=True)
            if policy.returncode != 0:
                errs.append(f"H1 {name} ({env}): security policy: {policy.stdout.strip().splitlines()[-3:]}")
            if have["kubeconform"]:
                loc = (["-schema-location", f"{schema_dir}/k8s/{{{{ .ResourceKind }}}}{{{{ .KindSuffix }}}}.json"] if schema_dir else ["-schema-location", "default"])
                kc = subprocess.run(["kubeconform", "-strict", "-summary", "-kubernetes-version", os.environ.get("KUBERNETES_VERSION", "1.35.6")] + loc + [str(rendered)], capture_output=True, text=True)
                if kc.returncode != 0:
                    errs.append(f"H1 {name} ({env}): kubeconform: {(kc.stdout + kc.stderr).strip().splitlines()[-1:]}")
            else:
                skipped.add("H1 kubeconform (not installed)")
    # D1
    for wf in snap["workflows"].values():
        for call in wf["calls"]:
            if call["uses"] != "build-image.yml":
                continue
            params = call["with"] or {}
            dockerfile = repo / str(params.get("context", ".")) / str(params.get("dockerfile", "Dockerfile"))
            if not dockerfile.exists():
                errs.append(f"D1 {name}: {dockerfile.relative_to(repo)} (dockerfile of the build call) does not exist")
                continue
            text = dockerfile.read_text(encoding="utf-8")
            mounted = set(re.findall(r"--mount=type=secret,id=([A-Za-z0-9_.-]+)", text))
            secrets = call["secrets"] if isinstance(call["secrets"], dict) else {}
            passed = {l.split("=", 1)[0].strip() for l in str(secrets.get("build-secrets", "")).splitlines() if "=" in l}
            if mounted - passed:
                errs.append(f"D1 {name}: the Dockerfile mounts BuildKit secrets {sorted(mounted - passed)} that the build call does not pass")
            if passed - mounted:
                errs.append(f"D1 {name}: the build call passes secrets {sorted(passed - mounted)} that the Dockerfile never mounts")
            if re.search(r"^\s*(ARG|ENV)\s+\S*(PASSWORD|SECRET|TOKEN|COMPOSER_AUTH|LICENSE_KEY)", text, re.M | re.I):
                errs.append(f"D1 {name}: the Dockerfile takes a credential through ARG or ENV (it would be stored in the image)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace")
    ap.add_argument("--write-snapshots", action="store_true")
    ap.add_argument("--expect-sha")
    ap.add_argument("--strict-sha", action="store_true")
    ap.add_argument("--against-pinned", action="store_true", help="also report how each caller fits the revision it pins today")
    ap.add_argument("--report")
    ap.add_argument("--manifest", default=str(ROOT / "tests/consumers.yaml"), help="list of consumers (tests use their own)")
    ap.add_argument("--snapshots", default=str(ROOT / "tests/consumers"), help="directory with <name>.json snapshots")
    ap.add_argument("--fail-on-stale-snapshot", action="store_true")
    a = ap.parse_args()

    manifest = yq_json(a.manifest)
    ifaces = candidate_interfaces(ROOT)
    chart_version = re.search(r"^version:\s*(\S+)", (ROOT / "charts/akjet-app/Chart.yaml").read_text(), re.M).group(1)
    snap_dir = pathlib.Path(a.snapshots)
    errs, notes, skipped, rows = [], [], set(), []
    all_refs, shared = {}, {}
    dk = ROOT / ".github/workflows/deploy-k8s.yml"

    for consumer in manifest["consumers"]:
        name = consumer["name"]
        repo = pathlib.Path(a.workspace) / name if a.workspace else None
        committed = snap_dir / f"{name}.json"
        source = "snapshot"
        if repo and (repo / ".github/workflows").is_dir():
            snap = extract(repo)
            source = "workspace"
            if a.write_snapshots:
                committed.parent.mkdir(exist_ok=True)
                committed.write_text(json.dumps(snap, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
            elif not committed.exists() or without_refs(json.loads(committed.read_text())) != without_refs(json.loads(json.dumps(snap))):
                (errs if a.fail_on_stale_snapshot else notes).append(
                    f"SNAPSHOT {name}: tests/consumers/{name}.json differs from the workspace - refresh with --write-snapshots")
        elif committed.exists():
            snap = json.loads(committed.read_text())
        else:
            errs.append(f"{name}: neither a workspace checkout nor tests/consumers/{name}.json")
            continue
        before = len(errs)
        refs = check_consumer(consumer, snap, ifaces, chart_version, errs, notes)
        all_refs[name] = refs
        got, identity = {}, {}
        for env in ("dev", "stage"):
            want = (consumer.get("namespace") or {}).get(env)
            ident, problem = resolve_identity(dk, snap, env)
            identity[env] = ident or {}
            got[env] = (ident or {}).get("namespace")
            if problem:
                errs.append(f"K9 {name} ({env}): {problem}")
            elif want and got[env] != want:
                errs.append(f"K9 {name}: values-{env}.yaml targets namespace {got[env]}, the platform provides {want}")
            if ident and ident.get("namespace"):
                shared.setdefault((env, ident["namespace"]), []).append((name, ident.get("release")))
        image = (snap.get("values") or {}).get("image")
        owner = consumer["repository"].split("/")[0].lower()
        if not image or not re.fullmatch(r"ghcr\.io/%s/[a-z0-9]([a-z0-9._/-]*[a-z0-9])?" % re.escape(owner), str(image)):
            errs.append(f"K12 {name}: image.repository of deploy/values.yaml must name an image under ghcr.io/{owner}/ (got {image!r})")
        for wf in snap["workflows"].values():
            for c in wf["calls"]:
                legacy = (c["with"] or {}).get("image") if c["uses"] == "build-image.yml" else None
                if legacy and image and f"ghcr.io/{owner}/{legacy}" != image:
                    errs.append(f"K12 {name}: the build call names image {legacy}, the values deploy {image}")
        if source == "workspace":
            check_repo(consumer, repo, snap, ROOT, errs, notes, skipped, identity)
        features = sorted({s for wf in snap["workflows"].values() for c in wf["calls"] if c["uses"] in REUSABLE and isinstance(c["secrets"], dict) for s in c["secrets"]})
        migrations = any("run-migrations" in (c["with"] or {}) for wf in snap["workflows"].values() for c in wf["calls"] if c["uses"] == "deploy-k8s.yml")
        rows.append((name, source, ",".join(sorted(r[:7] for r in refs)) or "-", got.get("dev") or "?", ", ".join(features) or "-",
                     "yes" if migrations else "no", "OK" if len(errs) == before else f"{len(errs) - before} error(s)"))

        if a.against_pinned and source == "workspace":
            for ref in sorted(refs - {ZERO}):
                shown = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{ref}^{{commit}}"], capture_output=True)
                if shown.returncode != 0:
                    notes.append(f"PINNED {name}: revision {ref[:7]} is not in the local clone of ci (fetch origin)")
                    continue
                with tempfile.TemporaryDirectory() as tmp:
                    old = {}
                    for f in REUSABLE:
                        text = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:.github/workflows/{f}"], capture_output=True, text=True)
                        if text.returncode == 0:
                            (pathlib.Path(tmp) / f).write_text(text.stdout)
                            old[f] = interface(yq_json(text=text.stdout))
                    olderrs = []
                    check_consumer(consumer, snap, old, chart_version, olderrs, [])
                    for env in ("dev", "stage"):
                        want = (consumer.get("namespace") or {}).get(env)
                        ident, problem = resolve_identity(pathlib.Path(tmp) / "deploy-k8s.yml", snap, env)
                        if ident is None and ((snap.get("values") or {}).get("deployment") or {}).get(env):
                            olderrs.append(f"K9 {name} ({env}): revision {ref[:7]} hands the values to Helm unchanged, and the chart rejects "
                                           "the deployment block - commit the values together with the new revision (scripts/update-ci-sha.sh)")
                        ns = (ident or {}).get("namespace") if ident is not None else resolve_namespace(pathlib.Path(tmp) / "deploy-k8s.yml", consumer["repository"], env)
                        if problem:
                            olderrs.append(f"K9 {name} ({env}): {problem}")
                        elif want and ns != want:
                            olderrs.append(f"K9 {name}: revision {ref[:7]} resolves {env} to namespace {ns}, the platform expects {want}")
                    for e in olderrs:
                        notes.append(f"PINNED@{ref[:7]} {e}")

    for (env, ns), members in sorted(shared.items()):
        releases = [r for _, r in members]
        if len(releases) != len(set(releases)):
            errs.append(f"K11 {env} namespace {ns}: {', '.join(f'{n}={r}' for n, r in members)} - services that share a namespace need different releases")
    distinct = sorted({r for refs in all_refs.values() for r in refs})
    if len(distinct) > 1:
        msg = "K10 consumers pin different revisions: " + ", ".join(f"{n}={'/'.join(sorted(x[:7] for x in r)) or '-'}" for n, r in all_refs.items())
        (errs if (a.strict_sha or a.expect_sha) else notes).append(msg)
    if a.expect_sha:
        for name, refs in all_refs.items():
            if refs != {a.expect_sha}:
                errs.append(f"K10 {name}: pins {sorted(refs)} instead of {a.expect_sha}")
    if a.strict_sha and ZERO in distinct:
        errs.append("K1 a consumer still carries the all-zero placeholder revision")

    head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() or "?"
    dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--", ".github/workflows", "charts"], capture_output=True, text=True).stdout.strip()
    lines = [f"consumers: candidate = working tree of ci at {head}{' + uncommitted changes' if dirty else ''} (not a published revision)",
             "interfaces of the candidate:"]
    for f, i in ifaces.items():
        ins = ", ".join(f"{k}{'*' if v['required'] else ''}:{v['type']}" for k, v in i["inputs"].items())
        lines.append(f"  {f}: inputs [{ins}]; secrets [{', '.join(i['secrets']) or '-'}]; outputs [{', '.join(i['outputs']) or '-'}]; token {i['permissions']}")
    hdr = ("consumer", "source", "pinned", "namespace (dev)", "secrets passed", "migrations", "candidate")
    width = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
    lines += ["  " + "  ".join(str(c).ljust(width[i]) for i, c in enumerate(r)).rstrip() for r in [hdr] + rows]
    lines += [f"  note: {n}" for n in notes]
    lines += [f"  skipped: {s}" for s in sorted(skipped)]
    lines += [f"  ERROR {e}" for e in errs]
    lines.append("consumers: static contract validation only - GitHub Actions did not run anything" + ("" if errs else "; ok"))
    report = "\n".join(lines)
    print(report)
    if a.report:
        pathlib.Path(a.report).write_text(report + "\n")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
