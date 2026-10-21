{{/*
Gateway API HTTPRoute, as an alternative to an Ingress.

Clusters increasingly have a Gateway and no ingress controller at all, in which
case an Ingress object is created, accepted by the API server, and then routes
nothing because no controller is watching. Offering both and checking which one
the cluster can actually serve is the difference between a working install and a
silent one.
*/}}
{{- define "common.httpRoute" -}}
{{- if .Values.route.enabled -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
  {{- with .Values.route.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  parentRefs:
    {{- range .Values.route.parentRefs }}
    - group: {{ .group | default "gateway.networking.k8s.io" }}
      kind: {{ .kind | default "Gateway" }}
      name: {{ required "route.parentRefs[].name is required" .name }}
      {{- with .namespace }}
      namespace: {{ . }}
      {{- end }}
      {{- with .sectionName }}
      sectionName: {{ . }}
      {{- end }}
      {{- with .port }}
      port: {{ . }}
      {{- end }}
    {{- end }}
  {{- with .Values.route.hostnames }}
  hostnames:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    - matches:
        - path:
            type: {{ .Values.route.pathType | default "PathPrefix" }}
            value: {{ .Values.route.path | default "/" }}
      {{- with .Values.route.timeouts }}
      timeouts:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.route.filters }}
      filters:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      backendRefs:
        - group: ""
          kind: Service
          name: {{ include "common.fullname" . }}
          port: {{ .Values.service.port }}
          weight: 1
{{- end -}}
{{- end -}}
