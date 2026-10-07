#!/usr/bin/env bash
# Start the LM Studio inference server (lms)
# Usage: lm-studio-start.sh
set -euo pipefail

BOOT="${HOME}/bin/lm-studio-boot.sh"
if [[ -x "$BOOT" ]]; then
  exec "$BOOT" start
fi

if ! command -v lms &>/dev/null; then
  if [[ -x /opt/lm-studio/lms ]]; then
    /opt/lm-studio/lms server start --bind 0.0.0.0 --port 1234
  else
    echo "lms CLI not found."
    exit 1
  fi
else
  lms server start --bind 0.0.0.0 --port 1234
fi
