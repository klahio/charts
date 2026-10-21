{{/*
Resolve the Ollama endpoint.

An explicit url wins. Otherwise, when the umbrella chart has Ollama enabled, we
build the in-cluster service name from the same fullname rule the Ollama
subchart uses, which keeps the two in step without the user wiring a hostname by
hand.
*/}}
{{- define "open-webui.ollamaUrl" -}}
{{- if .Values.ollama.url -}}
{{- .Values.ollama.url -}}
{{- else -}}
{{- $name := "ollama" -}}
{{- $fullname := "" -}}
{{- if contains $name .Release.Name -}}
{{- $fullname = .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $fullname = printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- printf "http://%s.%s.svc.cluster.local:11434" $fullname .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{- define "open-webui.secretName" -}}
{{- .Values.auth.existingSecret | default (printf "%s-auth" (include "common.fullname" .)) -}}
{{- end -}}

{{/*
Session signing key. Reuse the value already in the cluster when there is one,
so an upgrade does not silently invalidate every logged-in session. Only
generate on a genuinely first install.
*/}}
{{- define "open-webui.secretKey" -}}
{{- if .Values.auth.secretKey -}}
{{- .Values.auth.secretKey -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-auth" (include "common.fullname" .)) -}}
{{- if and $existing $existing.data (index $existing.data "WEBUI_SECRET_KEY") -}}
{{- index $existing.data "WEBUI_SECRET_KEY" | b64dec -}}
{{- else -}}
{{- randAlphaNum 48 -}}
{{- end -}}
{{- end -}}
{{- end -}}
