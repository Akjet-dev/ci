#!/usr/bin/env python3
"""Security checks for manifests rendered from charts/akjet-app.

Reads a JSON array of Kubernetes objects from stdin (`yq ea -o=json '[.]'`) and fails when an object
would not be admitted by the Pod Security "restricted" profile or breaks a rule of the chart:

  K1  only ConfigMap, ServiceAccount, Deployment, Service, HTTPRoute and Job may be rendered
      (no Secret, Namespace, NetworkPolicy, ResourceQuota, Gateway, RBAC ...)
  K2  no object sets metadata.namespace (the namespace comes from the deploy workflow only)
  K3  no object name refers to a production environment
  P1  pod: runAsNonRoot, seccomp RuntimeDefault, no ServiceAccount token, no host namespaces,
      volumes limited to emptyDir / secret / configMap
  P2  container: image pinned by digest, no privilege escalation, all capabilities dropped,
      not privileged, not root, read-only root filesystem, no hostPort, unprivileged ports,
      cpu/memory requests and a memory limit
  S1  no literal value under a variable or ConfigMap key that looks like a credential
  S2  Service is ClusterIP; ServiceAccount does not mount its token
  R1  HTTPRoute has explicit hostnames and a parent Gateway with name and namespace
  J1  migration Job: no retries, not a Helm hook, does not depend on the release ConfigMap

Usage: policy_check.py [--name LABEL] < objects.json
"""
import json
import re
import sys

ALLOWED_KINDS = {"ConfigMap", "ServiceAccount", "Deployment", "Service", "HTTPRoute", "Job"}
ALLOWED_VOLUMES = {"emptyDir", "secret", "configMap"}
IMAGE = re.compile(r"^[a-z0-9][a-z0-9.\-]*(:[0-9]+)?(/[a-z0-9][a-z0-9._\-]*)+@sha256:[a-f0-9]{64}$")
CREDENTIAL = re.compile(r"(PASSWORD|PASSWD|SECRET|TOKEN|ACCESS_KEY|(^|_)KEY$)", re.I)
PROD = re.compile(r"(^|[^a-z])prod", re.I)


def check_pod(ref, spec, errs):
    sc = spec.get("securityContext") or {}
    if sc.get("runAsNonRoot") is not True:
        errs.append(f"P1 {ref}: pod securityContext.runAsNonRoot must be true")
    if (sc.get("seccompProfile") or {}).get("type") != "RuntimeDefault":
        errs.append(f"P1 {ref}: seccompProfile.type must be RuntimeDefault")
    if sc.get("runAsUser") == 0:
        errs.append(f"P1 {ref}: runAsUser 0")
    if spec.get("automountServiceAccountToken") is not False:
        errs.append(f"P1 {ref}: automountServiceAccountToken must be false")
    for key in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(key):
            errs.append(f"P1 {ref}: {key} is set")
    for vol in spec.get("volumes") or []:
        kinds = set(vol) - {"name"}
        if not kinds <= ALLOWED_VOLUMES:
            errs.append(f"P1 {ref}: volume {vol.get('name')} uses {sorted(kinds - ALLOWED_VOLUMES)}")
    if spec.get("initContainers") or spec.get("ephemeralContainers"):
        errs.append(f"P1 {ref}: init/ephemeral containers are not rendered by this chart")
    for c in spec.get("containers") or []:
        cref = f"{ref}/{c.get('name')}"
        if not IMAGE.match(c.get("image", "")):
            errs.append(f"P2 {cref}: image {c.get('image')!r} is not <repository>@sha256:<digest>")
        csc = c.get("securityContext") or {}
        if csc.get("allowPrivilegeEscalation") is not False:
            errs.append(f"P2 {cref}: allowPrivilegeEscalation must be false")
        caps = csc.get("capabilities") or {}
        if "ALL" not in (caps.get("drop") or []) or caps.get("add"):
            errs.append(f"P2 {cref}: capabilities must drop ALL and add none")
        if csc.get("privileged"):
            errs.append(f"P2 {cref}: privileged")
        if csc.get("runAsUser") == 0 or csc.get("runAsNonRoot") is False:
            errs.append(f"P2 {cref}: runs as root")
        if csc.get("readOnlyRootFilesystem") is not True:
            errs.append(f"P2 {cref}: readOnlyRootFilesystem must be true in the test fixtures")
        for port in c.get("ports") or []:
            if port.get("hostPort"):
                errs.append(f"P2 {cref}: hostPort")
            if port.get("containerPort", 0) < 1024:
                errs.append(f"P2 {cref}: privileged containerPort {port.get('containerPort')}")
        res = c.get("resources") or {}
        req, lim = res.get("requests") or {}, res.get("limits") or {}
        if "cpu" not in req or "memory" not in req or "memory" not in lim:
            errs.append(f"P2 {cref}: cpu/memory requests and a memory limit are required")
        for env in c.get("env") or []:
            if "value" in env and CREDENTIAL.search(env.get("name", "")):
                errs.append(f"S1 {cref}: literal value for credential-like variable {env['name']}")


def check(objects, errs):
    for obj in objects:
        if not isinstance(obj, dict):
            continue
        kind, meta = obj.get("kind"), obj.get("metadata") or {}
        ref = f"{kind}/{meta.get('name')}"
        if kind not in ALLOWED_KINDS:
            errs.append(f"K1 {ref}: kind is not rendered by this chart")
            continue
        if "namespace" in meta:
            errs.append(f"K2 {ref}: metadata.namespace must not be set by the chart")
        if PROD.search(meta.get("name") or ""):
            errs.append(f"K3 {ref}: production name")

        if kind == "Deployment":
            check_pod(ref, obj["spec"]["template"]["spec"], errs)
        elif kind == "Job":
            spec = obj["spec"]
            pod = spec["template"]["spec"]
            check_pod(ref, pod, errs)
            if spec.get("backoffLimit") != 0:
                errs.append(f"J1 {ref}: backoffLimit must be 0")
            if any(k.startswith("helm.sh/hook") for k in (meta.get("annotations") or {})):
                errs.append(f"J1 {ref}: must not be a Helm hook")
            if pod.get("restartPolicy") != "Never":
                errs.append(f"J1 {ref}: restartPolicy must be Never")
            for c in pod.get("containers") or []:
                if any("configMapRef" in src for src in c.get("envFrom") or []):
                    errs.append(f"J1 {ref}: must not depend on the release ConfigMap")
        elif kind == "ConfigMap":
            for key in obj.get("data") or {}:
                if CREDENTIAL.search(key):
                    errs.append(f"S1 {ref}: credential-like key {key}")
        elif kind == "Service":
            if (obj.get("spec") or {}).get("type", "ClusterIP") != "ClusterIP":
                errs.append(f"S2 {ref}: type must be ClusterIP")
        elif kind == "ServiceAccount":
            if obj.get("automountServiceAccountToken") is not False:
                errs.append(f"S2 {ref}: automountServiceAccountToken must be false")
        elif kind == "HTTPRoute":
            spec = obj.get("spec") or {}
            hosts = spec.get("hostnames") or []
            if not hosts or any("*" in h for h in hosts):
                errs.append(f"R1 {ref}: explicit hostnames are required")
            for parent in spec.get("parentRefs") or [{}]:
                if not parent.get("name") or not parent.get("namespace"):
                    errs.append(f"R1 {ref}: parentRef needs name and namespace")


def main():
    label = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "--name" else "manifest"
    objects = json.load(sys.stdin)
    if not isinstance(objects, list) or not objects:
        print(f"policy-check {label}: no objects rendered", file=sys.stderr)
        return 1
    errs = []
    check(objects, errs)
    for err in errs:
        print(f"policy-check {label}: {err}", file=sys.stderr)
    if not errs:
        print(f"policy-check {label}: ok ({len(objects)} objects)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
