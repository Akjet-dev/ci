{{/* Release-scoped names. The release name is the service (or satellite) name; no chart name is added. */}}
{{- define "akjet-app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "akjet-app.componentName" -}}
{{- printf "%s-%s" .root.Release.Name .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "akjet-app.secretName" -}}
{{- printf "%s-%s" .root.Release.Name .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "akjet-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "akjet-app.fullname" . -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "akjet-app.image" -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- end -}}

{{- define "akjet-app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "akjet-app.selectorLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Rules JSON Schema cannot express. Rendering fails when:
  - a Secret reference (envFromSecrets, secretEnv, secretFiles) is not declared in requiredSecrets,
    or references a key that is not declared;
  - a probe, a Service or an HTTPRoute points to a port the component does not declare;
  - an HTTPRoute points to a component without a Service.
*/}}
{{- define "akjet-app.checkSecret" -}}
{{- $declared := .root.Values.requiredSecrets | default dict -}}
{{- if not (hasKey $declared .name) -}}
{{- fail (printf "%s: Secret %q is not declared in requiredSecrets" .where .name) -}}
{{- end -}}
{{- if .key -}}
{{- if not (has .key (get $declared .name)) -}}
{{- fail (printf "%s: key %q is not declared in requiredSecrets.%s" .where .key .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "akjet-app.checkRefs" -}}
{{- $root := .root -}}
{{- $where := .where -}}
{{- range .scope.envFromSecrets | default list -}}
{{- include "akjet-app.checkSecret" (dict "root" $root "where" (printf "%s.envFromSecrets" $where) "name" .) -}}
{{- end -}}
{{- range $var, $ref := .scope.secretEnv | default dict -}}
{{- include "akjet-app.checkSecret" (dict "root" $root "where" (printf "%s.secretEnv.%s" $where $var) "name" $ref.secret "key" $ref.key) -}}
{{- end -}}
{{- end -}}

{{- define "akjet-app.validate" -}}
{{- $root := . -}}
{{- include "akjet-app.checkRefs" (dict "root" $root "where" "values" "scope" .Values) -}}
{{- range .Values.secretFiles -}}
{{- include "akjet-app.checkSecret" (dict "root" $root "where" "secretFiles" "name" .secret "key" .key) -}}
{{- end -}}
{{- range $name, $c := .Values.components -}}
{{- include "akjet-app.checkRefs" (dict "root" $root "where" (printf "components.%s" $name) "scope" $c) -}}
{{- $ports := $c.ports | default dict -}}
{{- range $probe, $p := $c.probes | default dict -}}
{{- if and $p.path (not (hasKey $ports $p.port)) -}}
{{- fail (printf "components.%s.probes.%s: port %q is not declared in ports" $name $probe $p.port) -}}
{{- end -}}
{{- end -}}
{{- if and ($c.service | default dict).enabled (not $ports) -}}
{{- fail (printf "components.%s: service.enabled requires at least one port" $name) -}}
{{- end -}}
{{- end -}}
{{- if .Values.migration.enabled -}}
{{- include "akjet-app.checkRefs" (dict "root" $root "where" "migration" "scope" .Values.migration) -}}
{{- end -}}
{{- if .Values.httpRoute.enabled -}}
{{- range $i, $r := .Values.httpRoute.routes -}}
{{- $c := get $root.Values.components $r.component -}}
{{- if not $c -}}
{{- fail (printf "httpRoute.routes[%d]: component %q does not exist" $i $r.component) -}}
{{- end -}}
{{- if not ($c.service | default dict).enabled -}}
{{- fail (printf "httpRoute.routes[%d]: component %q has no Service (service.enabled)" $i $r.component) -}}
{{- end -}}
{{- if not (hasKey ($c.ports | default dict) ($r.port | default "http")) -}}
{{- fail (printf "httpRoute.routes[%d]: port %q is not declared by component %q" $i ($r.port | default "http") $r.component) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Pod- and container-level security settings required by the Pod Security "restricted" profile. */}}
{{- define "akjet-app.podSecurityContext" -}}
runAsNonRoot: true
{{- with .Values.podSecurity.runAsUser }}
runAsUser: {{ . }}
{{- end }}
{{- with .Values.podSecurity.runAsGroup }}
runAsGroup: {{ . }}
{{- end }}
{{- with .Values.podSecurity.fsGroup }}
fsGroup: {{ . }}
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "akjet-app.containerSecurityContext" -}}
allowPrivilegeEscalation: false
privileged: false
readOnlyRootFilesystem: {{ .Values.readOnlyRootFilesystem }}
capabilities:
  drop: ["ALL"]
{{- end -}}

{{/*
envFrom of a container. Order matters: a later source overrides an earlier one.
Input: root, scope (component or migration), configMap (bool)
*/}}
{{- define "akjet-app.envFrom" -}}
{{- $root := .root -}}
{{- $items := list -}}
{{- if and .configMap $root.Values.config -}}
{{- $items = append $items (dict "configMapRef" (dict "name" (printf "%s-config" (include "akjet-app.fullname" $root)))) -}}
{{- end -}}
{{- range concat ($root.Values.envFromSecrets | default list) (.scope.envFromSecrets | default list) | uniq -}}
{{- $items = append $items (dict "secretRef" (dict "name" (include "akjet-app.secretName" (dict "root" $root "name" .)))) -}}
{{- end -}}
{{- if $items -}}
{{- toYaml $items -}}
{{- end -}}
{{- end -}}

{{/*
env of a container: plain variables first, then secretKeyRef variables (release-wide, then scope-specific).
Input: root, plain (map of non-secret variables), scope
*/}}
{{- define "akjet-app.env" -}}
{{- $root := .root -}}
{{- $items := list -}}
{{- range $name := keys (.plain | default dict) | sortAlpha -}}
{{- $items = append $items (dict "name" $name "value" (get $.plain $name | toString)) -}}
{{- end -}}
{{- $refs := merge (dict) (.scope.secretEnv | default dict) ($root.Values.secretEnv | default dict) -}}
{{- range $name := keys $refs | sortAlpha -}}
{{- $ref := get $refs $name -}}
{{- $items = append $items (dict "name" $name "valueFrom" (dict "secretKeyRef" (dict "name" (include "akjet-app.secretName" (dict "root" $root "name" $ref.secret)) "key" $ref.key))) -}}
{{- end -}}
{{- if $items -}}
{{- toYaml $items -}}
{{- end -}}
{{- end -}}

{{/* Volumes and mounts: emptyDir per writable path, one read-only Secret volume per secretFiles entry. */}}
{{- define "akjet-app.volumeMounts" -}}
{{- $items := list -}}
{{- range $i, $path := .paths | default list -}}
{{- $items = append $items (dict "name" (printf "writable-%d" $i) "mountPath" $path) -}}
{{- end -}}
{{- range $i, $f := .root.Values.secretFiles -}}
{{- $items = append $items (dict "name" (printf "secret-file-%d" $i) "mountPath" $f.mountPath "subPath" (base $f.mountPath) "readOnly" true) -}}
{{- end -}}
{{- if $items -}}
{{- toYaml $items -}}
{{- end -}}
{{- end -}}

{{- define "akjet-app.volumes" -}}
{{- $root := .root -}}
{{- $items := list -}}
{{- range $i, $path := .paths | default list -}}
{{- $items = append $items (dict "name" (printf "writable-%d" $i) "emptyDir" (dict)) -}}
{{- end -}}
{{- range $i, $f := $root.Values.secretFiles -}}
{{- $items = append $items (dict "name" (printf "secret-file-%d" $i) "secret" (dict "secretName" (include "akjet-app.secretName" (dict "root" $root "name" $f.secret)) "items" (list (dict "key" $f.key "path" (base $f.mountPath))))) -}}
{{- end -}}
{{- if $items -}}
{{- toYaml $items -}}
{{- end -}}
{{- end -}}

{{- define "akjet-app.probe" -}}
{{- if .path -}}
httpGet:
  path: {{ .path }}
  port: {{ .port }}
{{- else -}}
exec:
  command: {{ toJson .exec }}
{{- end }}
{{- range $k := list "initialDelaySeconds" "periodSeconds" "timeoutSeconds" "failureThreshold" "successThreshold" }}
{{- if hasKey $ $k }}
{{ $k }}: {{ get $ $k }}
{{- end }}
{{- end }}
{{- end -}}
