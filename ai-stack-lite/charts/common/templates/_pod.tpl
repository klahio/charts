{{/*
Scheduling block shared by every component. nodeSelector, tolerations and
affinity fall back to the global values so a GPU node can be pinned once at the
umbrella level instead of three times.
*/}}
{{- define "common.scheduling" -}}
{{- $ns := .Values.nodeSelector -}}
{{- $tol := .Values.tolerations -}}
{{- $aff := .Values.affinity -}}
{{- with .Values.global -}}
{{- if and (not $ns) .nodeSelector }}{{- $ns = .nodeSelector }}{{- end -}}
{{- if and (not $tol) .tolerations }}{{- $tol = .tolerations }}{{- end -}}
{{- if and (not $aff) .affinity }}{{- $aff = .affinity }}{{- end -}}
{{- end -}}
{{- with $ns }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $tol }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $aff }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- end -}}

{{/*
Image reference. A digest wins over a tag when both are set, and the tag falls
back to the chart appVersion so values.yaml never has to carry "latest".
*/}}
{{- define "common.image" -}}
{{- $reg := .Values.image.registry | default "" -}}
{{- with .Values.global }}{{- if and (not $reg) .imageRegistry }}{{- $reg = .imageRegistry }}{{- end }}{{- end -}}
{{- $repo := .Values.image.repository -}}
{{- if $reg }}{{- $repo = printf "%s/%s" $reg $repo -}}{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
A helper image reference: the busybox and curl images the init containers and
the test pods use.

These go through global.imageRegistry like the component images do. Left out,
a cluster that mirrors everything into a private registry gets a stack whose
three application images resolve and whose init containers cannot pull, so
install fails at an ImagePullBackOff on busybox rather than on anything the
operator chose.

Usage: include "common.helperImage" (dict "ctx" . "image" "busybox:1.37")
*/}}
{{- define "common.helperImage" -}}
{{- $img := .image -}}
{{- with .ctx.Values.global }}{{- with .imageRegistry }}{{- $img = printf "%s/%s" . $img -}}{{- end }}{{- end -}}
{{- $img -}}
{{- end -}}

{{- define "common.imagePullSecrets" -}}
{{- $secrets := .Values.imagePullSecrets | default list -}}
{{- with .Values.global }}{{- with .imagePullSecrets }}{{- $secrets = concat $secrets . -}}{{- end }}{{- end -}}
{{- with $secrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
Probes. Rendered only when enabled, so a slow first model load can have probes
switched off entirely rather than tuned by guesswork.
*/}}
{{- define "common.probes" -}}
{{- $port := .port -}}
{{- with .probes -}}
{{- with .startup }}{{- if .enabled }}
startupProbe:
  httpGet:
    path: {{ .path | default "/" }}
    port: {{ $port }}
  initialDelaySeconds: {{ .initialDelaySeconds | default 10 }}
  periodSeconds: {{ .periodSeconds | default 10 }}
  failureThreshold: {{ .failureThreshold | default 60 }}
  timeoutSeconds: {{ .timeoutSeconds | default 5 }}
{{- end }}{{- end }}
{{- with .liveness }}{{- if .enabled }}
livenessProbe:
  httpGet:
    path: {{ .path | default "/" }}
    port: {{ $port }}
  initialDelaySeconds: {{ .initialDelaySeconds | default 30 }}
  periodSeconds: {{ .periodSeconds | default 20 }}
  failureThreshold: {{ .failureThreshold | default 6 }}
  timeoutSeconds: {{ .timeoutSeconds | default 5 }}
{{- end }}{{- end }}
{{- with .readiness }}{{- if .enabled }}
readinessProbe:
  httpGet:
    path: {{ .path | default "/" }}
    port: {{ $port }}
  initialDelaySeconds: {{ .initialDelaySeconds | default 10 }}
  periodSeconds: {{ .periodSeconds | default 10 }}
  failureThreshold: {{ .failureThreshold | default 6 }}
  timeoutSeconds: {{ .timeoutSeconds | default 5 }}
{{- end }}{{- end }}
{{- end -}}
{{- end -}}

{{/*
Environment variables from the simple map plus raw entries for valueFrom cases.
*/}}
{{- define "common.env" -}}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end -}}
{{- end -}}
