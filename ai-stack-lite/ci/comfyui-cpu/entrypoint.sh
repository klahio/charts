#!/bin/sh
# The subset of the default image's environment contract that the chart sets.
# COMFY_CMDLINE_EXTRA is left unquoted on purpose: it carries several flags.
set -e
set -- --listen "${LISTEN_ADDRESS:-0.0.0.0}" --port "${LISTEN_PORT:-8188}"
if [ -n "$BASE_DIRECTORY" ]; then
  # ComfyUI lists custom_nodes under the base directory at startup and exits
  # when it is missing. The default image's init script lays the tree out
  # before starting ComfyUI; this does the same for the parts ComfyUI expects.
  mkdir -p "$BASE_DIRECTORY/custom_nodes" "$BASE_DIRECTORY/input" "$BASE_DIRECTORY/user"
  set -- "$@" --base-directory "$BASE_DIRECTORY"
fi
# shellcheck disable=SC2086
exec python main.py "$@" $COMFY_CMDLINE_EXTRA
