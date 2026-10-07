#!/usr/bin/env bash
# Bring up headless LM Studio: llmster, API on :1234, default model load.
# Used by lm-studio.service (systemd --user). See README.md and LM-Studio-Optimization.md.
# Install: ~/dev/amd-halo/bin/install-lm-studio-service.sh (or ./setup.sh).
set -euo pipefail

LMS_BIND="${LMS_BIND:-0.0.0.0}"
LMS_PORT="${LMS_PORT:-1234}"
LMS_MODEL="${LMS_MODEL:-qwen/qwen3.6-35b-a3b}"
# Match LM-Studio-Optimization.md; override with LMS_LOAD_ARGS if needed.
LMS_LOAD_ARGS="${LMS_LOAD_ARGS:---gpu max -c 65536 --parallel 2}"

find_lms() {
  if [[ -n "${LMS_BIN:-}" && -x "${LMS_BIN}" ]]; then
    return 0
  fi
  local candidate
  for candidate in \
    "${HOME}/.lmstudio/bin/lms" \
    /opt/lm-studio/lms \
    /opt/lm-studio/bin/lms \
    "${HOME}/bin/lms"; do
    if [[ -x "$candidate" ]]; then
      LMS_BIN="$candidate"
      export PATH="${HOME}/.lmstudio/bin:$(dirname "$candidate"):${PATH}"
      return 0
    fi
  done
  if command -v lms &>/dev/null; then
    LMS_BIN="$(command -v lms)"
    return 0
  fi
  echo "lms CLI not found. Install LM Studio or set LMS_BIN." >&2
  return 1
}

lms_cmd() {
  "$LMS_BIN" "$@"
}

server_running() {
  lms_cmd server status 2>/dev/null | grep -q "running on port ${LMS_PORT}"
}

wait_for_daemon() {
  local i
  for i in $(seq 1 90); do
    if lms_cmd daemon status 2>/dev/null | grep -q 'is running'; then
      return 0
    fi
    sleep 2
  done
  echo "llmster did not become ready in time." >&2
  return 1
}

wait_for_api() {
  local i
  for i in $(seq 1 60); do
    if curl -sf --connect-timeout 2 "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "LM Studio API on port ${LMS_PORT} did not become ready in time." >&2
  return 1
}

model_loaded() {
  lms_cmd ps 2>/dev/null | grep -q "${LMS_MODEL}"
}

cmd_start() {
  find_lms
  lms_cmd daemon up

  wait_for_daemon

  if ! server_running; then
    lms_cmd server start --bind "${LMS_BIND}" --port "${LMS_PORT}"
  fi

  wait_for_api

  if ! model_loaded; then
    # shellcheck disable=SC2086
    lms_cmd load "${LMS_MODEL}" ${LMS_LOAD_ARGS}
  fi

  echo "LM Studio ready: http://${LMS_BIND}:${LMS_PORT} model=${LMS_MODEL}"
}

cmd_stop() {
  find_lms || exit 0
  lms_cmd server stop 2>/dev/null || true
  lms_cmd daemon down 2>/dev/null || true
}

case "${1:-start}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  *)
    echo "Usage: $(basename "$0") {start|stop}" >&2
    exit 1
    ;;
esac
