{{/*
Guess a sibling component's in-cluster URL.

Helm gives a subchart no view of its siblings' values, so this reproduces the
fullname rule the sibling uses and assumes the sibling's default port. That
holds for an ordinary umbrella install and breaks the moment the sibling is
renamed or moved to another port, because nothing here can see that it happened.
The guess is therefore only a default: whenever the sibling sets nameOverride,
fullnameOverride or a non-default service.port, or lives in another namespace or
another release, the url has to be given explicitly. Both call sites take one.

Usage: include "open-webui.siblingUrl" (dict "ctx" . "name" "ollama" "port" 11434)
*/}}
{{- define "open-webui.siblingUrl" -}}
{{- $ctx := .ctx -}}
{{- $name := .name -}}
{{- $fullname := "" -}}
{{- if contains $name $ctx.Release.Name -}}
{{- $fullname = $ctx.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $fullname = printf "%s-%s" $ctx.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- /* The cluster domain is a cluster-level setting, not something a chart can
       read, and "cluster.local" is only the common default. A cluster
       installed with a different one would get an unresolvable FQDN here. */}}
{{- printf "http://%s.%s.svc.%s:%v" $fullname $ctx.Release.Namespace $ctx.Values.clusterDomain .port -}}
{{- end -}}

{{/*
Resolve the Ollama endpoint. An explicit url wins; otherwise guess the sibling's.
*/}}
{{- define "open-webui.ollamaUrl" -}}
{{- if .Values.ollama.url -}}
{{- .Values.ollama.url -}}
{{- else -}}
{{- include "open-webui.siblingUrl" (dict "ctx" . "name" "ollama" "port" 11434) -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the ComfyUI endpoint, by the same rule.
*/}}
{{- define "open-webui.comfyuiUrl" -}}
{{- if .Values.imageGeneration.comfyui.url -}}
{{- .Values.imageGeneration.comfyui.url -}}
{{- else -}}
{{- include "open-webui.siblingUrl" (dict "ctx" . "name" "comfyui" "port" 8188) -}}
{{- end -}}
{{- end -}}

{{- define "open-webui.secretName" -}}
{{- .Values.auth.existingSecret | default (printf "%s-auth" (include "common.fullname" .)) -}}
{{- end -}}

{{/*
The value the Deployment hashes into its restart annotation.

It has to follow whichever Secret the pod actually reads. For a chart-managed
Secret that is the key below. For an existingSecret it is the key inside that
Secret, read from the cluster: hashing the generated key instead would hash a
value nothing uses, and since there is no <fullname>-auth Secret to find, a new
random one is produced on every render. The annotation would then change on
every upgrade and restart a pod whose configuration had not moved, which on this
chart's Recreate strategy is downtime rather than a rolling replacement.

Empty when the Secret cannot be read, which is the case under helm template and
whenever the external Secret is created outside Helm. The caller omits the
annotation entirely rather than hashing nothing, so an unreadable Secret costs
the restart-on-change behaviour and nothing else.
*/}}
{{- define "open-webui.authChecksum" -}}
{{- if .Values.auth.existingSecret -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace .Values.auth.existingSecret -}}
{{- if and $s $s.data (index $s.data "WEBUI_SECRET_KEY") -}}
{{- index $s.data "WEBUI_SECRET_KEY" | sha256sum -}}
{{- end -}}
{{- else -}}
{{- include "open-webui.secretKey" . | sha256sum -}}
{{- end -}}
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
{{- /* Generated once per render and remembered, because this helper is called
       from both the Secret and the Deployment's checksum annotation. Calling
       randAlphaNum twice hands them different keys, and the annotation then
       hashes a value nothing ever used: the install looks fine, and the first
       upgrade afterwards restarts the pod for no reason. */}}
{{- if not .Values.generatedSecretKey -}}
{{- $_ := set .Values "generatedSecretKey" (randAlphaNum 48) -}}
{{- end -}}
{{- .Values.generatedSecretKey -}}
{{- end -}}
{{- end -}}
{{- end -}}
