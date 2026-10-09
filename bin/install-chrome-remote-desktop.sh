#!/usr/bin/env bash
# Install and configure Google Chrome Remote Desktop on Debian-based systems.
# Idempotent. Safe to run alone after cloning amd-halo.
set -euo pipefail

# ── Fix the EPILOG bug in the CRD Python script ──────────────────────────────
# The upstream package has a triple-quoted string that gets corrupted during
# earlier setup attempts. This fix is applied before any CRD commands run.
fix_crd_epilog() {
  local file="/opt/google/chrome-remote-desktop/chrome-remote-desktop"
  [[ -f "$file" ]] || return 0

  # Check if the bug exists (broken EPILOG inside setup_argument_parser)
  if sed -n '2166,2175p' "$file" | grep -q 'EPILOG = """This script is not intended'; then
    # Remove the duplicate EPILOG blocks inside setup_argument_parser()
    # Lines 2167-2175 contain broken EPILOG assignments
    sudo sed -i '2167,2175d' "$file"
    # Add back a single correct EPILOG before the ArgumentParser call
    sudo sed -i '2166a\  EPILOG = """This script is not intended for use by end-users. To configure\n  Chrome Remote Desktop, please install the app from the Chrome\n  Web Store: https://chrome.google.com/remotedesktop"""\n' "$file"
    echo "Fixed EPILOG bug in chrome-remote-desktop script."
  fi

  # Add module-level EPILOG if it doesn't exist
  if ! grep -q '^EPILOG = """This script' "$file"; then
    sudo sed -i '/^def main():/i\
EPILOG = """This script is not intended for use by end-users. To configure\
Chrome Remote Desktop, please install the app from the Chrome\
Web Store: https://chrome.google.com/remotedesktop"""\
' "$file"
    echo "Added module-level EPILOG variable."
  fi
}

fix_crd_epilog

# ── Install ───────────────────────────────────────────────────────────────────
echo "Installing Google Chrome Remote Desktop..."
sudo apt-get update -qq
sudo apt-get install -y google-chrome-remote-desktop

# ── GNOME on Xorg session ────────────────────────────────────────────────────
# CRD does not attach to the GDM Wayland seat. This file is what the host
# runs after it starts its own X server. Do not point it at ~/.xsession:
# that file starts XFCE for xrdp.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install -m 755 "${REPO_DIR}/config/chrome-remote-desktop-session" \
  "${HOME}/.chrome-remote-desktop-session"
echo "Installed ${HOME}/.chrome-remote-desktop-session (GNOME on Xorg)."

# Wayland mode makes GNOME Shell look for an X display and exit, because the
# systemd unit registers the logind session as type x11.
if [[ -f "${HOME}/.zprofile" ]] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?CHROME_REMOTE_DESKTOP_USE_WAYLAND=' "${HOME}/.zprofile"; then
  echo "Warning: ${HOME}/.zprofile sets CHROME_REMOTE_DESKTOP_USE_WAYLAND." >&2
  echo "Remove that assignment. See RemoteDesktop.md." >&2
fi

# ── Add to PATH ──────────────────────────────────────────────────────────────
CRD_DIR="/opt/google/chrome-remote-desktop"
for rc in ~/.bashrc ~/.zshrc; do
  [[ -f "$rc" ]] || continue
  if ! grep -q 'chrome-remote-desktop' "$rc"; then
    echo "export PATH=\$PATH:${CRD_DIR}" >> "$rc"
    echo "Added CRD to PATH in $(basename "$rc")"
  fi
done

echo ""
echo "Chrome Remote Desktop installed."
echo "The boot service starts GNOME on Xorg from ~/.chrome-remote-desktop-session."
echo "Do not set CHROME_REMOTE_DESKTOP_USE_WAYLAND. See RemoteDesktop.md."
echo ""
echo "First-time pairing (from another computer):"
echo "  https://remotedesktop.google.com/headless"
echo ""
echo "Or:"
echo "  DISPLAY= ${CRD_DIR}/start-host \\"
echo "    --code=\"<OAuth_code_from_Google>\" \\"
echo "    --redirect-url=\"https://remotedesktop.google.com/_/oauthredirect\" \\"
echo "    --name=\$(hostname)"
echo ""
echo "Port 3389 is GNOME Remote Desktop (install-gnome-rdp.sh), not this host."
