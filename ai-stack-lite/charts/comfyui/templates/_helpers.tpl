{{/*
ComfyUI command line flags, assembled into the single environment variable the
image's init script appends to its python invocation.

The image entrypoint is a wrapper script, not ComfyUI itself, so passing flags
as container args would hand them to the wrapper and they would be ignored. That
failure is silent: the container starts, serves HTTP, and quietly runs with
whatever VRAM mode the image defaults to.
*/}}
{{- define "comfyui.cmdlineExtra" -}}
{{- $args := list -}}
{{/* "default" means pass nothing: ComfyUI's default is already the balanced
     mode, and the flag that used to name it was removed. */}}
{{- if and .Values.vramMode (ne .Values.vramMode "default") -}}
{{- $args = append $args (printf "--%s" .Values.vramMode) -}}
{{- end -}}
{{- if .Values.reserveVram -}}
{{- $args = append $args (printf "--reserve-vram %v" .Values.reserveVram) -}}
{{- end -}}
{{- range .Values.extraArgs }}{{- $args = append $args . -}}{{- end -}}
{{- join " " $args -}}
{{- end -}}

{{/*
The base directory the image is told to keep its tree in. Read from the
persistence entry rather than hardcoded, so moving the mount moves the setting
with it.
*/}}
{{- define "comfyui.baseDirectory" -}}
{{- $bd := "" -}}
{{- with .Values.persistence }}{{- with .basedir }}{{- if .enabled }}{{- $bd = .mountPath -}}{{- end }}{{- end }}{{- end -}}
{{- $bd -}}
{{- end -}}
