#!/usr/bin/env bash
# Installs the CPU profile, with ComfyUI switched on and running a CPU-only image
# built from ci/comfyui-cpu, and runs the helm tests against it. render-check.sh
# proves the templates render; this proves the result starts, pulls a model
# through the post-install Job, that the frontend can reach Ollama at the URL it
# was given, and that ComfyUI starts with the flags and directories the chart
# set. Needs docker and kind, and a kind cluster named $KIND_CLUSTER_NAME
# (charts-ci by default) as the current context: it installs into its own
# namespace and removes it after.
set -euo pipefail
cd "$(dirname "$0")/.."

release=ci-install
namespace=ai-stack-lite-ci

cleanup() {
  helm uninstall "$release" -n "$namespace" --wait >/dev/null 2>&1 || true
  # The chart keeps its claims on uninstall, so the namespace goes with them.
  kubectl delete namespace "$namespace" --wait=false >/dev/null 2>&1 || true
}

dump() {
  echo "==> install failed; cluster state follows" >&2
  kubectl -n "$namespace" get all,pvc,events -o wide >&2 || true
  for pod in $(kubectl -n "$namespace" get pods -o name 2>/dev/null); do
    echo "---- logs: $pod" >&2
    kubectl -n "$namespace" logs "$pod" --all-containers --tail=100 >&2 || true
  done
}

trap 'status=$?; [[ $status -ne 0 ]] && dump; cleanup; exit $status' EXIT

# Set COMFY_IMAGE_PRELOADED=1 on a cluster that is not kind, after putting
# ai-stack-lite-ci/comfyui-cpu:ci into each node's image store by other means.
if [[ "${COMFY_IMAGE_PRELOADED:-}" != 1 ]]; then
  echo "==> build the CPU-only ComfyUI image and load it into kind"
  comfy_image=ai-stack-lite-ci/comfyui-cpu:ci
  docker build -q -t "$comfy_image" ci/comfyui-cpu
  kind load docker-image "$comfy_image" --name "${KIND_CLUSTER_NAME:-charts-ci}"
fi

echo "==> helm install (values-cpu.yaml + ci/install-values.yaml)"
helm install "$release" . \
  -n "$namespace" --create-namespace \
  -f values-cpu.yaml -f ci/install-values.yaml \
  --wait --timeout 15m

echo "==> helm test"
helm test "$release" -n "$namespace" --logs --timeout 10m

echo "==> the puller left the model in place"
kubectl -n "$namespace" exec "statefulset/$release-ollama" -- ollama list \
  | grep -q '^smollm2:135m' || {
    echo "FAIL: smollm2:135m is not in ollama list after install" >&2
    exit 1
  }

# Asked of ComfyUI itself rather than of the volume: a file on disk under a
# directory ComfyUI does not read is exactly the failure worth catching.
comfy_get() {
  kubectl -n "$namespace" exec "deploy/$release-comfyui" -- \
    python -c "import sys, urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8188' + sys.argv[1]).read().decode())" "$1"
}

echo "==> comfyui sees the downloaded file under BASE_DIRECTORY"
comfy_get /models/vae_approx | grep -q '"taesd_decoder.safetensors"' || {
  echo "FAIL: comfyui does not list vae_approx/taesd_decoder.safetensors" >&2
  exit 1
}

echo "==> comfyui got --cpu from the chart"
comfy_get /system_stats | grep -qE '"type"[[:space:]]*:[[:space:]]*"cpu"' || {
  echo "FAIL: comfyui does not report a cpu device" >&2
  exit 1
}

echo "==> helm upgrade (no changes) settles again"
helm upgrade "$release" . \
  -n "$namespace" \
  -f values-cpu.yaml -f ci/install-values.yaml \
  --wait --timeout 10m
helm test "$release" -n "$namespace" --logs --timeout 10m

echo "OK"
