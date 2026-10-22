#!/usr/bin/env bash
# Installs the CPU profile into the current kubectl context and runs the helm
# tests against it. render-check.sh proves the templates render; this proves the
# result starts, pulls a model through the post-install Job, and that the
# frontend can reach Ollama at the URL it was given. Meant for a throwaway
# cluster such as kind: it installs into its own namespace and removes it after.
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

echo "==> helm upgrade (no changes) settles again"
helm upgrade "$release" . \
  -n "$namespace" \
  -f values-cpu.yaml -f ci/install-values.yaml \
  --wait --timeout 10m
helm test "$release" -n "$namespace" --logs --timeout 10m

echo "OK"
