#!/usr/bin/env bash
# GNOME Remote Desktop — system RDP on :3389 (GDM Remote Login).
# Sign in on the graphical login screen with your Linux user + password.
# Disables xrdp (same port). Does not use the old headless random-password path.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRD_USER="gnome-remote-desktop"
GRD_DATA="/var/lib/${GRD_USER}/.local/share/gnome-remote-desktop"
MAKECERT="/usr/bin/winpr-makecert3"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Enable GNOME Remote Desktop (system RDP, port 3389). Connect with Microsoft
Remote Desktop / Remmina; use the GDM login screen with your Linux account.

Required RDP gate (first prompt in the client — use the same values as Linux login):
  GRD_GATE_USER=eric GRD_GATE_PASSWORD='...' $(basename "$0")
Or run interactively (prompts for gate password).
Then sign in again on the GDM screen with Linux user + password.

  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

sudo apt-get update
sudo apt-get install -y gnome-remote-desktop winpr3-utils

sudo systemctl disable --now xrdp xrdp-sesman 2>/dev/null || true

if command -v grdctl &>/dev/null; then
  grdctl --headless rdp disable 2>/dev/null || true
  grdctl rdp disable 2>/dev/null || true
fi
systemctl --user disable --now gnome-remote-desktop-headless.service 2>/dev/null || true
systemctl --user disable --now gnome-remote-desktop.service 2>/dev/null || true

sudo mkdir -p "${GRD_DATA}"
sudo chown -R "${GRD_USER}:${GRD_USER}" "/var/lib/${GRD_USER}"

if [[ ! -s "${GRD_DATA}/tls.key" || ! -s "${GRD_DATA}/tls.crt" ]]; then
  sudo -u "${GRD_USER}" "${MAKECERT}" -silent -rdp -path "${GRD_DATA}" tls
fi

sudo grdctl --system rdp set-tls-key "${GRD_DATA}/tls.key"
sudo grdctl --system rdp set-tls-cert "${GRD_DATA}/tls.crt"
sudo grdctl --system rdp disable-view-only

GATE_USER="${GRD_GATE_USER:-${USER}}"
if [[ -z "${GRD_GATE_PASSWORD:-}" ]]; then
  if [[ -t 0 ]]; then
    echo -n "RDP gate password for ${GATE_USER} (use your Linux login password): "
    read -rs GRD_GATE_PASSWORD
    echo
  else
    echo "GNOME RDP requires gate credentials (empty gate causes client error 0x4)." >&2
    echo "Run:  sudo grdctl --system rdp set-credentials ${GATE_USER}" >&2
    echo "Then: sudo systemctl restart gnome-remote-desktop.service" >&2
    exit 1
  fi
fi
sudo grdctl --system rdp set-credentials "${GATE_USER}" "${GRD_GATE_PASSWORD}"
unset GRD_GATE_PASSWORD

sudo grdctl --system rdp enable
sudo systemctl enable --now gnome-remote-desktop.service

listening=0
for _ in $(seq 1 15); do
  if ss -ltn | awk '/:3389([^0-9]|$)/{found=1} END{exit found?0:1}'; then
    listening=1
    break
  fi
  sleep 1
done
if [[ "${listening}" -ne 1 ]]; then
  echo "GNOME RDP did not open port 3389." >&2
  sudo journalctl -u gnome-remote-desktop -n 40 --no-pager >&2 || true
  exit 1
fi

host="$(hostname -f 2>/dev/null || hostname)"
echo "GNOME Remote Desktop (system RDP) is on port 3389."
echo "  Computer: ${host}"
echo "  Then: GDM login with your Linux username and password."
echo "  (Accept the self-signed TLS certificate warning in the client.)"
echo
sudo grdctl --system status 2>/dev/null | sed -n '/^RDP:/,/^$/p' || true
