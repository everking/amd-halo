#!/usr/bin/env bash
# Disable idle suspend so LM Studio, cloudflared, and SSH stay up for days without local input.
# Safe to re-run (idempotent). Used by setup.sh for a remote-access server role.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGIND_DROPIN="/etc/systemd/logind.conf.d/99-server-no-suspend.conf"

run_gsettings() {
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  fi
  if ! command -v gsettings &>/dev/null; then
    echo "gsettings not found; skipping GNOME idle suspend (logind + mask still apply)." >&2
    return 0
  fi
  if ! gsettings list-schemas &>/dev/null 2>&1; then
    echo "No D-Bus session; skipping GNOME settings (run this script from a logged-in desktop/SSH with user bus)." >&2
    return 0
  fi
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0
  echo "GNOME: disabled automatic suspend on idle (AC and battery)."
}

install_logind_dropin() {
  sudo mkdir -p /etc/systemd/logind.conf.d
  sudo install -m 644 "${REPO_DIR}/config/logind/99-server-no-suspend.conf" "${LOGIND_DROPIN}"
  sudo systemctl restart systemd-logind.service || true
  echo "logind: installed ${LOGIND_DROPIN}"
}

mask_sleep_targets() {
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  echo "systemd: masked sleep/suspend/hibernate targets."
}

echo "=== Server power policy (no idle suspend) ==="
install_logind_dropin
mask_sleep_targets
run_gsettings

echo ""
echo "Done. Verify:"
echo "  gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type"
echo "  systemctl is-enabled sleep.target suspend.target  # should be masked"
echo "  systemctl --user status lm-studio.service cloudflared-llm.service"
