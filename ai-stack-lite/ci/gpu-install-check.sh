#!/usr/bin/env bash
# Installs the single-GPU profile onto a cluster with a real NVIDIA card and runs
# the helm tests against it. install-check.sh proves the stack starts on CPU;
# this proves the parts it cannot: that the runtime class and the GPU limit put
# the device inside the containers, that Ollama actually runs a model on it, and
# that ComfyUI starts on CUDA from the default image. Written for the one-node
# k3s that infra/aws-gpu-ci/runner builds, but needs only helm, kubectl, a
# current context with nvidia.com/gpu advertised, and RuntimeClass nvidia.
set -euo pipefail
cd "$(dirname "$0")/.."

release=ci-gpu
namespace=ai-stack-lite-gpu-ci
model=qwen2.5:0.5b

cleanup() {
  helm uninstall "$release" -n "$namespace" --wait >/dev/null 2>&1 || true
  # The chart keeps its claims on uninstall, so the namespace goes with them.
  kubectl delete namespace "$namespace" --wait=false >/dev/null 2>&1 || true
}

dump() {
  echo "==> install failed; cluster state follows" >&2
  kubectl get nodes -o wide >&2 || true
  kubectl describe node >&2 || true
  kubectl -n "$namespace" get all,pvc,events -o wide >&2 || true
  for pod in $(kubectl -n "$namespace" get pods -o name 2>/dev/null); do
    echo "---- logs: $pod" >&2
    kubectl -n "$namespace" logs "$pod" --all-containers --tail=100 >&2 || true
  done
}

trap 'status=$?; [[ $status -ne 0 ]] && dump; cleanup; exit $status' EXIT

echo "==> helm dependency build"
helm dependency build . >/dev/null
for c in charts/*/; do
  [[ -f "$c/Chart.yaml" ]] || continue
  if grep -q '^dependencies:' "$c/Chart.yaml"; then
    helm dependency build "$c" >/dev/null
  fi
done

echo "==> the node's GPU"
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

# ComfyUI builds its virtualenv on first boot, which on a fresh volume is most
# of the wait here.
echo "==> helm install (values-single-gpu.yaml + ci/gpu-install-values.yaml)"
helm install "$release" . \
  -n "$namespace" --create-namespace \
  -f values-single-gpu.yaml -f ci/gpu-install-values.yaml \
  --wait --timeout 45m

# Each GPU component's test pod asks for a device and runs nvidia-smi in it.
echo "==> helm test"
helm test "$release" -n "$namespace" --logs --timeout 15m

echo "==> the device is visible inside the running workloads"
kubectl -n "$namespace" exec "statefulset/$release-ollama" -- nvidia-smi -L
kubectl -n "$namespace" exec "deploy/$release-comfyui" -- nvidia-smi -L

# A visible device is not the same as a used one: Ollama falls back to CPU
# silently when its CUDA libraries do not match the driver. ollama ps reports
# where the loaded model actually sits.
echo "==> ollama runs $model on the GPU"
kubectl -n "$namespace" exec "statefulset/$release-ollama" -- \
  ollama run "$model" "Reply with the single word: ok" >/dev/null
processor=$(kubectl -n "$namespace" exec "statefulset/$release-ollama" -- ollama ps)
echo "$processor"
echo "$processor" | grep -q 'GPU' || {
  echo "FAIL: $model is loaded but not on the GPU" >&2
  exit 1
}

# python3, not python: the default image only has the interpreter it builds
# its virtualenv from on PATH, and exec does not activate that virtualenv.
comfy_get() {
  kubectl -n "$namespace" exec "deploy/$release-comfyui" -- \
    python3 -c "import sys, urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8188' + sys.argv[1]).read().decode())" "$1"
}

echo "==> comfyui runs on cuda"
comfy_get /system_stats | grep -qE '"type"[[:space:]]*:[[:space:]]*"cuda"' || {
  echo "FAIL: comfyui does not report a cuda device" >&2
  comfy_get /system_stats >&2 || true
  exit 1
}

echo "==> comfyui sees the downloaded file under BASE_DIRECTORY"
comfy_get /models/vae_approx | grep -q '"taesd_decoder.safetensors"' || {
  echo "FAIL: comfyui does not list vae_approx/taesd_decoder.safetensors" >&2
  exit 1
}

echo "OK"
