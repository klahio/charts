{{/*
Renders one PersistentVolumeClaim per enabled entry in .Values.persistence.
Entries that point at an existingClaim render nothing, because the claim is
owned elsewhere and must survive helm uninstall.

Call with the chart context. Expects .Values.persistence to be a map of
name -> { enabled, size, accessMode, storageClass, existingClaim, mountPath }.
*/}}
{{- define "common.pvcs" -}}
{{- $ctx := . -}}
{{- range $key, $p := .Values.persistence -}}
{{- $vol := $key | kebabcase | lower -}}
{{- if and (kindIs "map" $p) $p.enabled (not $p.existingClaim) }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ printf "%s-%s" (include "common.fullname" $ctx) $vol }}
  labels:
    {{- include "common.labels" $ctx | nindent 4 }}
    ai-stack-lite/volume: {{ $vol }}
  {{- /* Keep model data when the release goes away. Re-downloading tens of
         gigabytes of weights because of a helm uninstall is not recoverable
         cheaply. */}}
  annotations:
    helm.sh/resource-policy: {{ $p.resourcePolicy | default "keep" | quote }}
spec:
  accessModes:
    - {{ $p.accessMode | default "ReadWriteOnce" }}
  resources:
    requests:
      storage: {{ required (printf "persistence.%s.size is required" $key) $p.size }}
  {{- with $p.storageClass }}
  storageClassName: {{ . }}
  {{- end }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
volumes: entries matching the PVCs above, plus any extraVolumes.
*/}}
{{- define "common.volumes" -}}
{{- $ctx := . -}}
{{- range $key, $p := .Values.persistence -}}
{{- if and (kindIs "map" $p) $p.enabled }}
- name: {{ $key | kebabcase | lower }}
  persistentVolumeClaim:
    claimName: {{ $p.existingClaim | default (printf "%s-%s" (include "common.fullname" $ctx) ($key | kebabcase | lower)) }}
{{- end -}}
{{- end -}}
{{- range $key, $p := .Values.persistence -}}
{{- if and (kindIs "map" $p) (not $p.enabled) }}
- name: {{ $key | kebabcase | lower }}
  emptyDir: {}
{{- end -}}
{{- end -}}
{{- with .Values.extraVolumes }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{/*
volumeMounts matching the volumes above.
*/}}
{{- define "common.volumeMounts" -}}
{{- range $key, $p := .Values.persistence -}}
{{- if kindIs "map" $p }}
- name: {{ $key | kebabcase | lower }}
  mountPath: {{ required (printf "persistence.%s.mountPath is required" $key) $p.mountPath }}
  {{- with $p.subPath }}
  subPath: {{ . }}
  {{- end }}
{{- end -}}
{{- end -}}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{/*
An init container that fixes ownership of the mounted volume roots.

A freshly provisioned PersistentVolume is owned by root. podSecurityContext
fsGroup changes the group but never the owning uid, so an image that insists on
owning its data directory outright cannot start on a new volume. The usual
symptom is a container that exits immediately complaining about the directory
owner, which looks like a chart bug and is really a property of how volumes are
provisioned.

Only the mount roots are changed, not their contents. Recursing would mean
walking every model file on every pod start.

Usage: include "common.chownInit" (dict "ctx" . "uid" 1024 "gid" 1024)
*/}}
{{- define "common.chownInit" -}}
{{- $ctx := .ctx -}}
{{- $uid := .uid -}}
{{- $gid := .gid -}}
- name: fix-volume-ownership
  image: {{ .image | default "busybox:1.37" }}
  imagePullPolicy: IfNotPresent
  securityContext:
    runAsUser: 0
    runAsNonRoot: false
  command:
    - sh
    - -c
    - |
      set -e
      {{- range $key, $p := $ctx.Values.persistence }}
      {{- if kindIs "map" $p }}
      chown {{ $uid }}:{{ $gid }} {{ $p.mountPath }}
      chmod 0775 {{ $p.mountPath }}
      echo "{{ $p.mountPath }} -> {{ $uid }}:{{ $gid }}"
      {{- end }}
      {{- end }}
  volumeMounts:
    {{- include "common.volumeMounts" $ctx | nindent 4 }}
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
{{- end -}}
