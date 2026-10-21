#!/usr/bin/env bash
# Renders every profile and validates the output. Runs without a cluster, in
# which case the install-time lookup checks are skipped and only rendering is
# verified. With a reachable cluster, pass --server to also validate the
# manifests against the API server and exercise the preflight checks.
set -euo pipefail
cd "$(dirname "$0")/.."

server=false
[[ "${1:-}" == "--server" ]] && server=true

echo "==> helm dependency build"
helm dependency build . >/dev/null
for c in charts/*/; do
  [[ -f "$c/Chart.yaml" ]] || continue
  grep -q '^dependencies:' "$c/Chart.yaml" && helm dependency build "$c" >/dev/null
done

echo "==> helm lint"
helm lint .
for c in charts/*/; do helm lint "$c"; done

echo "==> render profiles"
for f in values.yaml values-cpu.yaml values-single-gpu.yaml; do
  echo "    -- $f"
  helm template ci-test . -f "$f" >/dev/null
done

echo "==> render each subchart standalone"
for c in charts/ollama charts/open-webui charts/comfyui; do
  echo "    -- $c"
  helm template ci-test "$c" >/dev/null
done

if [[ "$server" == true ]]; then
  echo "==> validate manifests against the API server"
  for f in values.yaml values-cpu.yaml values-single-gpu.yaml; do
    echo "    -- $f"
    helm template ci-test . -f "$f" | kubectl apply --dry-run=server -f - >/dev/null
  done

  echo "==> preflight checks should reject a bad GPU request"
  if helm install ci-test . --dry-run=server --set global.gpu.count=999 >/dev/null 2>&1; then
    echo "FAIL: preflight accepted an impossible GPU count" >&2
    exit 1
  fi
  echo "    -- rejected as expected"

  echo "==> preflight checks should reject a missing RuntimeClass"
  if helm install ci-test . --dry-run=server \
       --set global.gpu.runtimeClassName=does-not-exist >/dev/null 2>&1; then
    echo "FAIL: preflight accepted a nonexistent RuntimeClass" >&2
    exit 1
  fi
  echo "    -- rejected as expected"

  echo "==> preflight skip should override both"
  helm install ci-test . --dry-run=server \
    --set global.gpu.runtimeClassName=does-not-exist \
    --set global.preflight.skip=true >/dev/null
  echo "    -- waived as expected"
fi

echo "OK"
