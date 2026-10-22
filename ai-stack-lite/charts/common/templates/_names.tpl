{{/*
Expanded chart name, truncated to the 63 character limit DNS names carry.
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. If the release name already contains the chart name we
do not repeat it, so a release called "ollama" does not become "ollama-ollama".
*/}}
{{- define "common.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels applied to every object. extraLabels from the parent chart's global block
land here too, which is how cluster-wide label policies get satisfied.

The chart's own keys are emitted last and removed from the user's set first, so
extraLabels cannot produce a duplicate key for one of them. Dumping the user's
map with toYaml beside these lines did exactly that, and YAML keeps the last of
a duplicated key: an extraLabels entry for app.kubernetes.io/name silently
rewrote the object's identity.

Values are quoted because a Kubernetes label value must be a string. A
cost-centre or team label written as a bare number reaches toYaml as an integer
and the API server rejects the object with "must be a string", which is a
strange way to find out that the quoting differed between an object's labels and
its pod's.
*/}}
{{- define "common.labels" -}}
{{- $reserved := list "helm.sh/chart" "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/version" "app.kubernetes.io/managed-by" "app.kubernetes.io/part-of" -}}
{{- $extra := dict -}}
{{- with .Values.global }}{{- with .extraLabels }}{{- $extra = mergeOverwrite $extra (deepCopy .) -}}{{- end }}{{- end -}}
{{- with .Values.extraLabels }}{{- $extra = mergeOverwrite $extra (deepCopy .) -}}{{- end -}}
{{- range $k := $reserved }}{{- $_ := unset $extra $k -}}{{- end -}}
helm.sh/chart: {{ include "common.chart" . }}
{{ include "common.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ai-stack-lite
{{- range $k, $v := $extra }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Labels for a pod template.

The selector labels, plus extraLabels and podLabels from both the global block
and the component. extraLabels has to reach pods and not just the owning object:
a cluster whose admission policy demands a team or cost-centre label rejects the
Pod, not the Deployment, so a label that stops at the workload object produces a
release that applies cleanly and then never starts anything.
*/}}
{{- define "common.podLabels" -}}
{{- $labels := dict -}}
{{- /* Least specific first, because mergeOverwrite lets each later layer win.
       That matches the precedence the umbrella's values file states for every
       other global: applied to every component unless the component overrides
       it. Within a scope, podLabels beats extraLabels, being the pod-specific
       one of the two. */}}
{{- with .Values.global }}
{{- with .extraLabels }}{{- $labels = mergeOverwrite $labels (deepCopy .) -}}{{- end }}
{{- with .podLabels }}{{- $labels = mergeOverwrite $labels (deepCopy .) -}}{{- end }}
{{- end }}
{{- with .Values.extraLabels }}{{- $labels = mergeOverwrite $labels (deepCopy .) -}}{{- end }}
{{- with .Values.podLabels }}{{- $labels = mergeOverwrite $labels (deepCopy .) -}}{{- end }}
{{- /* The selector keys are removed rather than merely emitted first. YAML
       takes the last of a duplicated key, so leaving them in would let an
       extraLabels entry for app.kubernetes.io/name rewrite the pod's copy while
       the workload's immutable spec.selector kept the original - and a pod
       template whose labels do not match the selector is rejected outright with
       "selector does not match template labels". A mandatory-label policy
       colliding with these keys is unlikely, but the failure if it happened
       would be an install that cannot proceed at all. */}}
{{- $_ := unset $labels "app.kubernetes.io/name" -}}
{{- $_ := unset $labels "app.kubernetes.io/instance" -}}
{{- include "common.selectorLabels" . }}
{{- range $k, $v := $labels }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{/*
Pod labels for the one pod per component that actually serves the Service.

The two selector labels alone do not distinguish a serving pod from the other
pods this chart creates in the same release: the model-puller Job and every helm
test pod carry the same name and instance, so they match the Service selector
too. Today they are spared from the Service's endpoints only because its
targetPort is named and they declare no port by that name - an implicit rescue
that stops working the moment anyone gives a test pod a port. Marking the
serving pod and selecting on the mark makes the Service say what it means.

The workload's own spec.selector keeps the two bare labels, because a selector
is immutable once the object exists and narrowing it would break every upgrade
of an existing release. A Service selector is mutable, which is why the
distinction can be made on this side.
*/}}
{{- define "common.servingPodLabels" -}}
{{- include "common.podLabels" . }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "common.serviceSelectorLabels" -}}
{{- include "common.selectorLabels" . }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "common.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "common.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
