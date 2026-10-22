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
{{- $gpu := fromJson (include "common.gpu" .) -}}
{{/*
"default" means pass nothing: ComfyUI's default is already the balanced mode,
and the flag that used to name it was removed.

The exception is an install with no GPU. ComfyUI looks for a CUDA device at
startup and exits when it finds none, so a pod scheduled without a GPU
crashloops on what reads as an image problem. --cpu is the flag that makes it
run anyway, and nothing but this chart knows the GPU was turned off, so the
default mode resolves to it rather than to no flag. An explicit vramMode is left
alone: someone naming a mode has a reason, and overriding it here would be the
same silent substitution in the other direction.
*/}}
{{- if and .Values.vramMode (ne .Values.vramMode "default") -}}
{{- $args = append $args (printf "--%s" .Values.vramMode) -}}
{{- else if not $gpu.enabled -}}
{{- $args = append $args "--cpu" -}}
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

{{/*
The two paths that have to agree.

ComfyUI reads checkpoints from BASE_DIRECTORY/models, and the downloader writes
them to persistence.models.mountPath. Nothing ties the two together, so moving
the basedir mount without moving the models mount leaves the weights where they
were: the init container succeeds, the pod starts, and every workflow fails at
the loader with an empty checkpoint list. Say so at render time instead.
*/}}
{{- define "comfyui.checkPaths" -}}
{{- $bd := include "comfyui.baseDirectory" . -}}
{{- if $bd -}}
{{- with .Values.persistence }}{{- with .models }}{{- if .enabled -}}
{{- $want := printf "%s/models" $bd -}}
{{- if ne .mountPath $want -}}
{{- fail (printf "\n\nai-stack-lite: comfyui model paths disagree.\n\nComfyUI reads checkpoints from BASE_DIRECTORY/models, which this configuration\nmakes %q, but persistence.models.mountPath is %q. The downloader would write the\nweights where nothing reads them, and every workflow would fail at the loader\nwith no checkpoints listed.\n\nSet persistence.models.mountPath to %q, or move persistence.basedir.mountPath so\nthat the two line up.\n" $want .mountPath $want) -}}
{{- end -}}
{{- end }}{{- end }}{{- end -}}
{{- end -}}
{{- end -}}
