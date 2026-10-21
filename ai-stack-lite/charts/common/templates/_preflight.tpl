{{/*
Install-time checks against the live cluster.

lookup returns an empty result during client-side rendering, so every branch
here is guarded on having actually read something. The practical effect: these
checks fire on helm install and on helm install --dry-run=server, and are
skipped by helm template, which keeps CI rendering green without a cluster.

Each check can be waived with preflight.skip, because a check that is wrong must
never be the reason an install cannot proceed.
*/}}
{{- define "common.preflight" -}}
{{- $skip := false -}}
{{- with .Values.global }}{{- with .preflight }}{{- $skip = .skip | default false -}}{{- end }}{{- end -}}
{{- if not $skip -}}
{{- include "common.preflight.gpu" . -}}
{{- include "common.preflight.storage" . -}}
{{- include "common.preflight.exposure" . -}}
{{- end -}}
{{- end -}}

{{/*
If the component asks for a GPU, make sure the cluster can actually give it one.
*/}}
{{- define "common.preflight.gpu" -}}
{{- $g := fromJson (include "common.gpu" .) -}}
{{- if $g.enabled -}}
{{- $nodes := (lookup "v1" "Node" "" "").items -}}
{{- if $nodes -}}
  {{- $total := 0 -}}
  {{- range $nodes -}}
    {{- $total = add $total (int (index .status.allocatable "nvidia.com/gpu" | default 0)) -}}
  {{- end -}}
  {{- if eq $total 0 -}}
    {{- fail (printf "\n\nai-stack-lite preflight: no node advertises nvidia.com/gpu.\n\nThe chart does not install GPU support. Install the NVIDIA container toolkit on\nthe node and a device plugin, then retry. On a single GPU node:\n\n  sudo apt-get install -y nvidia-container-toolkit\n  sudo nvidia-ctk runtime configure --runtime=containerd\n  sudo systemctl restart containerd\n  kubectl label node <node> nvidia.com/gpu.present=true\n  helm install nvdp nvdp/nvidia-device-plugin -n nvidia-device-plugin --create-namespace --set runtimeClassName=nvidia\n\nTo install without a GPU instead, set global.gpu.enabled=false.\nTo bypass this check, set global.preflight.skip=true.\n") -}}
  {{- else if lt $total ($g.count | int) -}}
    {{- fail (printf "\n\nai-stack-lite preflight: the cluster advertises %d nvidia.com/gpu but this component requests %d.\n\nEnable time-slicing in the device plugin to advertise more replicas than there\nare physical cards, or lower the gpu.count value.\n" $total ($g.count | int)) -}}
  {{- end -}}
  {{- if $g.runtimeClassName -}}
    {{- $rc := lookup "node.k8s.io/v1" "RuntimeClass" "" $g.runtimeClassName -}}
    {{- if not $rc -}}
      {{- fail (printf "\n\nai-stack-lite preflight: RuntimeClass %q does not exist.\n\nGPU pods need it, because the containerd default runtime does not inject the\nNVIDIA libraries. Without it a pod starts and then fails with\n\"nvidia-smi: not found\". Create it with:\n\n  kubectl apply -f - <<'EOF'\n  apiVersion: node.k8s.io/v1\n  kind: RuntimeClass\n  metadata:\n    name: %s\n  handler: %s\n  EOF\n\nIf the nvidia runtime is already your containerd default, clear the value with\n--set global.gpu.runtimeClassName=\"\" instead.\n" $g.runtimeClassName $g.runtimeClassName $g.runtimeClassName) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
A PVC with no storageClassName and no default StorageClass stays Pending with no
obvious cause, so catch it before the release exists.
*/}}
{{- define "common.preflight.storage" -}}
{{- if .Values.persistence -}}
{{- range $key, $p := .Values.persistence -}}
{{- if and (kindIs "map" $p) $p.enabled (not $p.existingClaim) (not $p.storageClass) -}}
{{- $scs := (lookup "storage.k8s.io/v1" "StorageClass" "" "").items -}}
{{- if $scs -}}
  {{- $default := false -}}
  {{- range $scs -}}
    {{- $ann := .metadata.annotations | default dict -}}
    {{- if or (eq (index $ann "storageclass.kubernetes.io/is-default-class" | default "") "true") (eq (index $ann "storageclass.beta.kubernetes.io/is-default-class" | default "") "true") -}}
      {{- $default = true -}}
    {{- end -}}
  {{- end -}}
  {{- if not $default -}}
    {{- fail (printf "\n\nai-stack-lite preflight: persistence %q needs a StorageClass.\n\nThe cluster has no default StorageClass, so the PVC would stay Pending forever.\nSet persistence.%s.storageClass to one of the available classes, or point\npersistence.%s.existingClaim at a PVC you already have.\n" $key $key $key) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Checks for whichever way the component is exposed.

An Ingress on a cluster with no ingress controller, and an HTTPRoute whose
hostname does not intersect any listener on its parent Gateway, both produce the
same result: an object the API server accepts and nothing serves. Neither shows
up as an error unless somebody goes looking.
*/}}
{{- define "common.preflight.exposure" -}}
{{- if and .Values.ingress .Values.ingress.enabled -}}
{{- $classes := (lookup "networking.k8s.io/v1" "IngressClass" "" "").items -}}
{{- $nodes := (lookup "v1" "Node" "" "").items -}}
{{- if and $nodes (not $classes) -}}
  {{- fail (printf "\n\nai-stack-lite preflight: ingress is enabled but the cluster has no IngressClass.\n\nNothing is watching Ingress objects, so the one this chart creates would be\naccepted and then route nothing. Either install an ingress controller, or expose\nthe component through the Gateway API instead:\n\n  ingress.enabled=false\n  route.enabled=true\n  route.parentRefs[0].name=<your gateway>\n\nTo bypass this check, set global.preflight.skip=true.\n") -}}
{{- end -}}
{{- if and $classes .Values.ingress.className -}}
  {{- $found := false -}}
  {{- range $classes }}{{- if eq .metadata.name $.Values.ingress.className }}{{- $found = true -}}{{- end }}{{- end -}}
  {{- if not $found -}}
    {{- $names := list -}}
    {{- range $classes }}{{- $names = append $names .metadata.name -}}{{- end -}}
    {{- fail (printf "\n\nai-stack-lite preflight: IngressClass %q does not exist.\n\nAvailable: %s\n" .Values.ingress.className (join ", " $names)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.route .Values.route.enabled -}}
{{- range $ref := .Values.route.parentRefs -}}
{{- $ns := $ref.namespace | default $.Release.Namespace -}}
{{- $gw := lookup "gateway.networking.k8s.io/v1" "Gateway" $ns $ref.name -}}
{{- $probe := lookup "gateway.networking.k8s.io/v1" "Gateway" "" "" -}}
{{- if $probe.items -}}
  {{- if not $gw -}}
    {{- fail (printf "\n\nai-stack-lite preflight: Gateway %q not found in namespace %q.\n\nSet route.parentRefs[].name and .namespace to a Gateway that exists.\n" $ref.name $ns) -}}
  {{- end -}}
  {{- $listeners := $gw.spec.listeners | default list -}}
  {{- if $ref.sectionName -}}
    {{- $match := false -}}
    {{- range $listeners }}{{- if eq .name $ref.sectionName }}{{- $match = true -}}{{- end }}{{- end -}}
    {{- if not $match -}}
      {{- $names := list -}}
      {{- range $listeners }}{{- $names = append $names .name -}}{{- end -}}
      {{- fail (printf "\n\nai-stack-lite preflight: Gateway %s/%s has no listener named %q.\n\nListeners on that Gateway: %s\n" $ns $ref.name $ref.sectionName (join ", " $names)) -}}
    {{- end -}}
  {{- end -}}
  {{/* A hostname that intersects no listener is the quiet failure worth catching. */}}
  {{- with $.Values.route.hostnames -}}
    {{- range $host := . -}}
      {{- $ok := false -}}
      {{- range $l := $listeners -}}
        {{- if or (not $ref.sectionName) (eq $l.name $ref.sectionName) -}}
          {{- $lh := $l.hostname | default "" -}}
          {{- if not $lh -}}
            {{- $ok = true -}}
          {{- else if eq $lh $host -}}
            {{- $ok = true -}}
          {{- else if hasPrefix "*." $lh -}}
            {{- if hasSuffix (trimPrefix "*" $lh) $host -}}{{- $ok = true -}}{{- end -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
      {{- if not $ok -}}
        {{- $hosts := list -}}
        {{- range $l := $listeners }}{{- with $l.hostname }}{{- $hosts = append $hosts . -}}{{- end }}{{- end -}}
        {{- fail (printf "\n\nai-stack-lite preflight: hostname %q matches no listener on Gateway %s/%s.\n\nThe HTTPRoute would be created and then serve nothing, because a route only\nattaches where its hostname intersects the listener's.\n\nListener hostnames: %s\n\nEither pick a hostname under one of those, or add a listener for %q to that\nGateway.\n" $host $ns $ref.name (join ", " $hosts) $host) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
