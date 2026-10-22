{{/*
Resolve the effective GPU settings for a component.

Precedence, lowest to highest: built-in default, global.gpu, the component's own
gpu block. Resolution is key by key with hasKey rather than a dict merge,
because sprig's merge treats false as an absent value: a component setting
enabled: false would be silently overwritten by a global enabled: true. That bug
is quiet and expensive, since it hands a GPU to a frontend that cannot use one
while the component that needs it waits for the resource.
*/}}
{{- define "common.gpu" -}}
{{- $out := dict "enabled" false "count" 1 "runtimeClassName" "" -}}
{{- $layers := list -}}
{{- with .Values.global }}{{- with .gpu }}{{- $layers = append $layers . -}}{{- end }}{{- end -}}
{{- with .Values.gpu }}{{- $layers = append $layers . -}}{{- end -}}
{{- range $layer := $layers -}}
  {{- range $k := list "enabled" "count" "runtimeClassName" -}}
    {{- if hasKey $layer $k -}}
      {{- $_ := set $out $k (index $layer $k) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{/*
A count of zero means no GPU, so it collapses to enabled: false rather than
staying a separate state. Otherwise every consumer has to re-check the count:
common.resources already omits the limit at zero, but a pod would still get the
runtimeClassName, and the helm tests would still assert that a device is visible
inside a container that was never given one. One rule here, and all of them
agree.
*/}}
{{- if le ($out.count | int) 0 -}}
{{- $_ := set $out "enabled" false -}}
{{- end -}}
{{- if not $out.enabled -}}
{{- $_ := set $out "count" 0 -}}
{{- $_ := set $out "runtimeClassName" "" -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/*
runtimeClassName line for a pod spec. On clusters where the nvidia runtime is
not the containerd default, omitting this yields a pod that schedules and starts
but has no GPU libraries inside the container, so the workload fails at runtime
rather than at admission. That silent mode is why this is wired to the GPU
toggle instead of being left to the user to remember.
*/}}
{{- define "common.runtimeClassName" -}}
{{- $g := fromJson (include "common.gpu" .) -}}
{{- if and $g.enabled $g.runtimeClassName -}}
runtimeClassName: {{ $g.runtimeClassName }}
{{- end -}}
{{- end -}}

{{/*
Container resources with the GPU limit merged in. A GPU is only ever a limit:
Kubernetes requires an extended resource request to equal its limit, and
rejects a request with no matching limit.
*/}}
{{- define "common.resources" -}}
{{- $g := fromJson (include "common.gpu" .) -}}
{{- $res := deepCopy (default (dict) .Values.resources) -}}
{{- if and $g.enabled (gt ($g.count | int) 0) -}}
{{- $limits := deepCopy (default (dict) (get $res "limits")) -}}
{{- $_ := set $limits "nvidia.com/gpu" ($g.count | int) -}}
{{- $_ := set $res "limits" $limits -}}
{{- end -}}
{{- if $res }}
{{- toYaml $res }}
{{- else }}
{{- dict | toYaml }}
{{- end }}
{{- end -}}
