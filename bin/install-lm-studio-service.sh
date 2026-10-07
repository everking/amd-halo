#!/usr/bin/env bash
# Install LM Studio headless boot: ~/bin scripts, systemd user unit, linger.
# Idempotent. Invoked by setup.sh; safe to run alone after cloning amd-halo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_SYSTEMD="${HOME}/.config/systemd/user"

mkdir -p "${HOME}/bin" "${USER_SYSTEMD}"

install -m 755 "${REPO_DIR}/bin/lm-studio-boot.sh" "${HOME}/bin/lm-studio-boot.sh"
install -m 755 "${REPO_DIR}/bin/lm-studio-start.sh" "${HOME}/bin/lm-studio-start.sh"
install -m 644 "${REPO_DIR}/config/lm-studio.service" "${USER_SYSTEMD}/lm-studio.service"

if loginctl show-user "${USER}" 2>/dev/null | grep -q 'Linger=no'; then
  echo "Enabling systemd user linger for ${USER} (services at boot without login)..."
  if ! loginctl enable-linger "${USER}" 2>/dev/null; then
    sudo loginctl enable-linger "${USER}"
  fi
fi

systemctl --user daemon-reload
systemctl --user enable lm-studio.service

echo "Installed lm-studio.service (enabled)."
echo "  Start now:  systemctl --user start lm-studio.service"
echo "  Status:     systemctl --user status lm-studio.service"
echo "  Logs:       journalctl --user -u lm-studio.service -b"
