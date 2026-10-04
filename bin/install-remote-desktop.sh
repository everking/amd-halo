#!/usr/bin/env bash
# Install GNOME Remote Desktop when it is missing, then start headless RDP.
# Re-running keeps an existing certificate and password.
set -euo pipefail

CONF_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/gnome-remote-desktop"
TLS_KEY="${CONF_DIR}/tls.key"
TLS_CERT="${CONF_DIR}/tls.crt"
PASSWORD_FILE="${CONF_DIR}/rdp-password"
UNIT="gnome-remote-desktop-headless.service"
SHELL_UNIT="gnome-shell-headless.service"
SHELL_UNIT_PATH="${HOME}/.config/systemd/user/${SHELL_UNIT}"
RDP_USER="${RDP_USER:-${USER}}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Install gnome-remote-desktop if not installed, then enable headless RDP
for ${RDP_USER}. First run creates a TLS cert and password.

  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! dpkg -s gnome-remote-desktop &>/dev/null; then
  if ! sudo -n true 2>/dev/null; then
    echo "gnome-remote-desktop is not installed, and sudo needs a password." >&2
    echo "Install it with: sudo apt-get install -y gnome-remote-desktop" >&2
    exit 1
  fi
  sudo apt-get update
  sudo apt-get install -y gnome-remote-desktop
fi

if ! command -v grdctl &>/dev/null; then
  echo "grdctl not found after installing gnome-remote-desktop." >&2
  exit 1
fi
if ! command -v openssl &>/dev/null; then
  echo "openssl is required." >&2
  exit 1
fi

mkdir -p "${CONF_DIR}"
chmod 700 "${CONF_DIR}"

if [[ ! -s "${TLS_KEY}" || ! -s "${TLS_CERT}" ]]; then
  openssl req -new -newkey rsa-2048 -days 720 -nodes -x509 \
    -subj "/CN=$(hostname)" \
    -out "${TLS_CERT}" -keyout "${TLS_KEY}"
  chmod 600 "${TLS_KEY}" "${TLS_CERT}"
fi

grdctl --headless rdp set-tls-key "${TLS_KEY}"
grdctl --headless rdp set-tls-cert "${TLS_CERT}"
grdctl --headless rdp disable-view-only

current_user="$(grdctl --headless status 2>/dev/null | awk -F': ' '/^Username:/{print $2; exit}')"
created_password=0
if [[ -z "${current_user}" || "${current_user}" == "(empty)" ]]; then
  password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  grdctl --headless rdp set-credentials "${RDP_USER}" "${password}"
  umask 077
  printf '%s\n' "${password}" > "${PASSWORD_FILE}"
  chmod 600 "${PASSWORD_FILE}"
  created_password=1
fi

grdctl --headless rdp disable-view-only
grdctl --headless rdp enable
gsettings set org.gnome.desktop.remote-desktop.rdp view-only false
gsettings set org.gnome.desktop.remote-desktop.rdp enable true

mkdir -p "${HOME}/.config/systemd/user"
cat > "${SHELL_UNIT_PATH}" <<EOF
[Unit]
Description=Headless GNOME Shell for Remote Desktop
Before=${UNIT}

[Service]
Type=simple
ExecStart=/usr/bin/gnome-shell --headless --no-x11
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

mkdir -p "${HOME}/.config/systemd/user/${UNIT}.d"
cat > "${HOME}/.config/systemd/user/${UNIT}.d/shell.conf" <<EOF
[Unit]
After=${SHELL_UNIT}
Wants=${SHELL_UNIT}
EOF

systemctl --user daemon-reload
systemctl --user enable "${SHELL_UNIT}" "${UNIT}"
systemctl --user restart "${SHELL_UNIT}"

ready=0
for _ in $(seq 1 30); do
  if busctl --user status org.gnome.Mutter.RemoteDesktop &>/dev/null \
    && busctl --user status org.gnome.Mutter.ScreenCast &>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
  echo "Headless GNOME Shell did not export the remote desktop API." >&2
  journalctl --user -u "${SHELL_UNIT}" -n 30 --no-pager >&2 || true
  exit 1
fi

systemctl --user restart "${UNIT}"

listening=0
for _ in $(seq 1 20); do
  if ss -ltn | awk '/:3389([^0-9]|$)/{found=1} END{exit found?0:1}'; then
    listening=1
    break
  fi
  sleep 1
done
if [[ "${listening}" -ne 1 ]]; then
  echo "GNOME Remote Desktop did not open port 3389." >&2
  journalctl --user -u "${UNIT}" -n 30 --no-pager >&2 || true
  exit 1
fi

echo "Headless GNOME Remote Desktop is running (RDP, port 3389)."
echo "User: ${RDP_USER}"
if [[ "${created_password}" -eq 1 ]]; then
  echo "Password file: ${PASSWORD_FILE}"
else
  echo "Kept the existing RDP password."
fi

if [[ "$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
  echo
  echo "This user service stops when your login session ends."
  echo "Keep it running after logout with: sudo loginctl enable-linger ${USER}"
fi
