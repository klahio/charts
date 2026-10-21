{{/*
A retry wrapper for test commands.

helm test can start the moment an upgrade returns, which is before a Recreate
rollout has finished. Without a retry the test races the pod it is testing and
fails on a healthy install, which trains everyone to ignore it. Retrying costs
nothing when things are fine and removes the race when they are not.

Usage: include "common.testRetry" (dict "attempts" 30 "interval" 5)
*/}}
{{- define "common.testRetry" -}}
attempts={{ .attempts | default 30 }}
interval={{ .interval | default 5 }}
retry() {
  desc="$1"; shift
  i=1
  while [ "$i" -le "$attempts" ]; do
    if "$@"; then
      return 0
    fi
    echo "  $desc not ready yet (attempt $i of $attempts)"
    i=$((i + 1))
    sleep "$interval"
  done
  echo "FAIL: $desc did not succeed within $((attempts * interval))s"
  return 1
}
{{- end -}}
