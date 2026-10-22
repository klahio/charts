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
{{- include "common.preflight.orphanedClaims" . -}}
{{- include "common.preflight.exposure" . -}}
{{- end -}}
{{- end -}}

{{/*
The claims this chart keeps on purpose are the claims that block reinstalling it.

Every PVC carries helm.sh/resource-policy: keep, so a helm uninstall leaves the
data behind - which is the point, because the alternative is re-downloading tens
of gigabytes of weights. The cost is that a later helm install under the same
release name tries to create a PVC that already exists, and Helm 3 refuses to
adopt an object it does not own: "invalid ownership metadata". The release fails
having created part of itself, and the reason given names a PVC rather than the
uninstall that left it.

So say it before anything is created, with the two ways out. Install only: on an
upgrade these claims belong to the release already.
*/}}
{{- define "common.preflight.orphanedClaims" -}}
{{- if and .Release.IsInstall .Values.persistence -}}
{{- $ctx := . -}}
{{- range $key, $p := .Values.persistence -}}
{{- if and (kindIs "map" $p) $p.enabled (not $p.existingClaim) -}}
{{- $name := printf "%s-%s" (include "common.fullname" $ctx) ($key | kebabcase | lower) -}}
{{- $pvc := lookup "v1" "PersistentVolumeClaim" $ctx.Release.Namespace $name -}}
{{- if $pvc -}}
{{- $ann := $pvc.metadata.annotations | default dict -}}
{{- $owner := index $ann "meta.helm.sh/release-name" | default "" -}}
{{- if ne $owner $ctx.Release.Name -}}
{{- fail (printf "\n\nai-stack-lite preflight: PersistentVolumeClaim %q already exists in namespace %q.\n\nIt was kept by a previous uninstall, because the chart annotates its claims\nhelm.sh/resource-policy: keep so that model weights survive. Helm will not\nadopt a claim it does not own, so this install would fail partway through.\n\nTo reuse the data, point the chart at the claim instead of creating it:\n\n  --set persistence.%s.existingClaim=%s\n\nTo let Helm own it again, hand it over:\n\n  kubectl -n %s annotate pvc %s meta.helm.sh/release-name=%s meta.helm.sh/release-namespace=%s --overwrite\n  kubectl -n %s label pvc %s app.kubernetes.io/managed-by=Helm --overwrite\n\nTo start over and lose the data:\n\n  kubectl -n %s delete pvc %s\n" $name $ctx.Release.Namespace $key $name $ctx.Release.Namespace $name $ctx.Release.Name $ctx.Release.Namespace $ctx.Release.Namespace $name $ctx.Release.Namespace $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
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
  {{- /* Only nodes a pod could actually land on. A cordoned or NotReady node
         keeps advertising its devices, so counting them turns this check into
         one that passes while the pod it was protecting stays Pending - the
         exact outcome the check exists to prevent, now with the install
         reporting success. */}}
  {{- $total := 0 -}}
  {{- $skipped := 0 -}}
  {{- range $nodes -}}
    {{- $gpus := int (index .status.allocatable "nvidia.com/gpu" | default 0) -}}
    {{- $ready := false -}}
    {{- range (.status.conditions | default list) -}}
      {{- if and (eq .type "Ready") (eq .status "True") -}}{{- $ready = true -}}{{- end -}}
    {{- end -}}
    {{- $schedulable := not (.spec.unschedulable | default false) -}}
    {{- if and $ready $schedulable -}}
      {{- $total = add $total $gpus -}}
    {{- else if gt $gpus 0 -}}
      {{- $skipped = add $skipped $gpus -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $total 0 -}}
    {{- if gt $skipped 0 -}}
      {{- fail (printf "\n\nai-stack-lite preflight: the only nodes advertising nvidia.com/gpu (%d in total) are cordoned or not Ready.\n\nNothing can be scheduled onto them, so the GPU pods would stay Pending. Check:\n\n  kubectl get nodes\n\nUncordon the node, or wait for it to become Ready, then retry.\nTo bypass this check, set global.preflight.skip=true.\n" $skipped) -}}
    {{- end -}}
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
{{- /* Whether this is a live cluster is decided by the Node list, not by the
       StorageClass list. Guarding on $scs instead would skip the check on the
       one cluster that needs it most: a cluster with no StorageClass at all
       returns an empty list, which is indistinguishable from the empty list
       helm template returns, so the install that is certain to leave every PVC
       Pending forever was the install that sailed through. */}}
{{- $nodes := (lookup "v1" "Node" "" "").items -}}
{{- if $nodes -}}
  {{- $default := false -}}
  {{- range $scs -}}
    {{- $ann := .metadata.annotations | default dict -}}
    {{- if or (eq (index $ann "storageclass.kubernetes.io/is-default-class" | default "") "true") (eq (index $ann "storageclass.beta.kubernetes.io/is-default-class" | default "") "true") -}}
      {{- $default = true -}}
    {{- end -}}
  {{- end -}}
  {{- if not $default -}}
    {{- $names := list -}}
    {{- range $scs }}{{- $names = append $names .metadata.name -}}{{- end -}}
    {{- if $scs -}}
      {{- fail (printf "\n\nai-stack-lite preflight: persistence %q needs a StorageClass.\n\nThe cluster has StorageClasses but none of them is the default, so the PVC\nwould stay Pending forever.\n\nAvailable: %s\n\nSet persistence.%s.storageClass to one of those, or point\npersistence.%s.existingClaim at a PVC you already have.\n" $key (join ", " $names) $key $key) -}}
    {{- else -}}
      {{- fail (printf "\n\nai-stack-lite preflight: persistence %q needs a StorageClass.\n\nThe cluster has no StorageClass at all, so the PVC would stay Pending forever.\nInstall a storage provisioner first. On a single node, local-path is enough:\n\n  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml\n  kubectl patch storageclass local-path -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'\n\nOr point persistence.%s.existingClaim at a PVC you already have.\n" $key $key) -}}
    {{- end -}}
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
{{- if $classes -}}
  {{- $names := list -}}
  {{- range $classes }}{{- $names = append $names .metadata.name -}}{{- end -}}
  {{- if .Values.ingress.className -}}
    {{- $found := false -}}
    {{- range $classes }}{{- if eq .metadata.name $.Values.ingress.className }}{{- $found = true -}}{{- end }}{{- end -}}
    {{- if not $found -}}
      {{- fail (printf "\n\nai-stack-lite preflight: IngressClass %q does not exist.\n\nAvailable: %s\n" .Values.ingress.className (join ", " $names)) -}}
    {{- end -}}
  {{- else -}}
    {{- /* An empty className means the cluster has to supply a default, exactly
           as an empty storageClass does. Without one the Ingress is created
           with no class, no controller claims it, and it routes nothing - the
           same quiet failure the check above exists to prevent, reached by
           leaving a field alone instead of filling it in wrong. */}}
    {{- $default := false -}}
    {{- range $classes -}}
      {{- $ann := .metadata.annotations | default dict -}}
      {{- if eq (index $ann "ingressclass.kubernetes.io/is-default-class" | default "") "true" -}}
        {{- $default = true -}}
      {{- end -}}
    {{- end -}}
    {{- if not $default -}}
      {{- fail (printf "\n\nai-stack-lite preflight: ingress.className is empty and the cluster has no default IngressClass.\n\nThe Ingress would be created with no class, and no controller would claim it.\n\nAvailable: %s\n\nSet ingress.className to one of those, or mark one as the cluster default:\n\n  kubectl annotate ingressclass <name> ingressclass.kubernetes.io/is-default-class=true\n" (join ", " $names)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.route .Values.route.enabled -}}
{{- range $ref := .Values.route.parentRefs -}}
{{- $ns := $ref.namespace | default $.Release.Namespace -}}
{{- /* An empty name has to be caught before the lookup. Helm turns a lookup
       with no name into a list of the whole namespace, which comes back as a
       non-nil map and therefore reads as "the Gateway exists"; the checks below
       then describe listeners of a GatewayList and fail with a message about a
       Gateway called "". The route template's own `required` would catch it,
       but only after this has already produced the confusing error. */}}
{{- if not $ref.name -}}
  {{- fail (printf "\n\nai-stack-lite preflight: route.enabled is true but route.parentRefs[].name is empty.\n\nAn HTTPRoute has to name the Gateway it attaches to, and this chart cannot\nguess it. Set it to a Gateway in namespace %q, or set its .namespace too:\n\n  route:\n    enabled: true\n    parentRefs:\n      - name: my-gateway\n        namespace: gateway\n" $ns) -}}
{{- end -}}
{{- $gw := lookup "gateway.networking.k8s.io/v1" "Gateway" $ns $ref.name -}}
{{- /* Live-cluster probe, by the same reasoning as the StorageClass check:
       a cluster with no Gateway at all returns an empty list, so guarding on
       that list alone would skip the check exactly when route.enabled is wrong.
       The Node list is the thing that is empty only under helm template. */}}
{{- $nodes := (lookup "v1" "Node" "" "").items -}}
{{- if $nodes -}}
  {{- if not $gw -}}
    {{- fail (printf "\n\nai-stack-lite preflight: Gateway %q not found in namespace %q.\n\nSet route.parentRefs[].name and .namespace to a Gateway that exists. If the\ncluster has no Gateway API at all, expose the component through an Ingress\ninstead:\n\n  route.enabled=false\n  ingress.enabled=true\n\nTo bypass this check, set global.preflight.skip=true.\n" $ref.name $ns) -}}
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
  {{/*
  A route whose hostnames intersect no listener is the quiet failure worth
  catching. The rule is intersection, and it is symmetric: the listener may be a
  wildcard covering the route's name, and the route may equally be a wildcard
  covering the listener's. Testing only the first direction rejects route
  "*.example.internal" against listener "ai.example.internal", a pairing the
  Gateway API accepts and serves.

  The route as a whole needs one intersection, not one per hostname. A route
  attaches to the listeners it matches and the rest of its hostnames are simply
  ignored, so failing on a list where some entries belong to another parent
  would block a valid multi-parent route.
  */}}
  {{- with $.Values.route.hostnames -}}
    {{- $ok := false -}}
    {{- range $host := . -}}
      {{- range $l := $listeners -}}
        {{- if or (not $ref.sectionName) (eq $l.name $ref.sectionName) -}}
          {{- $lh := $l.hostname | default "" -}}
          {{- if or (not $lh) (eq $lh $host) -}}
            {{- $ok = true -}}
          {{- else if hasPrefix "*." $lh -}}
            {{- if hasSuffix (trimPrefix "*" $lh) $host -}}{{- $ok = true -}}{{- end -}}
          {{- else if hasPrefix "*." $host -}}
            {{- if hasSuffix (trimPrefix "*" $host) $lh -}}{{- $ok = true -}}{{- end -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- if not $ok -}}
      {{- $hosts := list -}}
      {{- range $l := $listeners }}{{- with $l.hostname }}{{- $hosts = append $hosts . -}}{{- end }}{{- end -}}
      {{- fail (printf "\n\nai-stack-lite preflight: no hostname in [%s] intersects a listener on Gateway %s/%s.\n\nThe HTTPRoute would be created and then serve nothing, because a route only\nattaches to a listener whose hostname intersects its own.\n\nListener hostnames: %s\n\nEither pick a hostname covered by one of those, or add a matching listener to\nthat Gateway.\n" (join ", " .) $ns $ref.name (join ", " $hosts)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
