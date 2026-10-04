#!/usr/bin/env bash
# Point https://llm.m634.dev at a local origin through a Cloudflare Tunnel.
# Re-running is safe: it reuses the "llm" tunnel, refreshes the config, and restarts the service.
# This replaces any existing DNS record for llm.m634.dev.
#
# Pass a TCP port or a full http(s) URL. A port is http://127.0.0.1:<port>.
# With no origin, the tunnel uses the origin proxy on port 13315.
set -euo pipefail

HOSTNAME_BASE="m634.dev"
LEMONADE_ORIGIN="http://127.0.0.1:13305"
# Lemonade rejects the public Origin. The proxy strips it, then forwards.
PROXY_ORIGIN="http://127.0.0.1:13315"
PROXY_UNIT="llm-origin-proxy.service"
CF_DIR="${HOME}/.cloudflared"

FOREGROUND=0
PREFIX=""
ORIGIN_ARG=""

usage() {
  cat <<EOF
Usage: $(basename "$0") <prefix> [url|port] [--foreground]

Create or reuse a Cloudflare Tunnel for ${HOSTNAME_BASE}, route it to the 
given origin, and start it as a user service.

  <prefix>      Domain prefix. The hostname will be <prefix>.${HOSTNAME_BASE}.
                 This also determines the tunnel name and service unit.
  [url|port]    Tunnel origin. A port number means http://127.0.0.1:<port>.
                 A full http:// or https:// URL is used as given.
  --foreground  Run cloudflared in this terminal instead of the user service
  -h, --help    Show this help

Example:
  $(basename "$0") my-bot 8080
  $(basename "$0") ai-proxy https://api.example.com --foreground
EOF
}

# Print the tunnel origin on stdout. A bare port becomes a loopback URL.
normalize_origin() {
  local raw="$1"
  local port
  if [[ "${raw}" =~ ^[0-9]+$ ]]; then
    if (( ${#raw} > 5 )); then
      echo "Port must be from 1 to 65535, got: ${raw}" >&2
      exit 2
    fi
    port=$((10#${raw}))
    if (( port < 1 || port > 65535 )); then
      echo "Port must be from 1 to 65535, got: ${raw}" >&2
      exit 2
    fi
    printf 'http://127.0.0.1:%s\n' "${port}"
    return
  fi
  if [[ "${raw}" =~ ^https?://[^[:space:]]+$ ]]; then
    printf '%s\n' "${raw%/}"
    return
  fi
  echo "Expected a port number or an http(s) URL, got: ${raw}" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreground) FOREGROUND=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${PREFIX}" ]]; then
        PREFIX="$1"
      elif [[ -z "${ORIGIN_ARG}" ]]; then
        ORIGIN_ARG="$1"
      else
        echo "Too many positional arguments. Expected <prefix> and [url|port]." >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "${PREFIX}" || -z "${ORIGIN_ARG}" ]]; then
  echo "Error: Both <prefix> and [url|port] are required." >&2
  usage >&2
  exit 2
fi

HOSTNAME="${PREFIX}.${HOSTNAME_BASE}"
TUNNEL_NAME="llm-${PREFIX}"
CONFIG="${CF_DIR}/config-${TUNNEL_NAME}.yml"
UNIT_NAME="cloudflared-llm-${PREFIX}.service"
UNIT_PATH="${HOME}/.config/systemd/user/${UNIT_NAME}"

ORIGIN="$(normalize_origin "${ORIGIN_ARG}")"

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "cloudflared is not on PATH." >&2
  exit 1
fi
CLOUDFLARED="$(command -v cloudflared)"

if [[ ! -f "${CF_DIR}/cert.pem" ]]; then
  echo "No Cloudflare origin certificate at ${CF_DIR}/cert.pem." >&2
  echo "Log in first: cloudflared tunnel login" >&2
  exit 1
fi

if [[ "${ORIGIN}" == "${PROXY_ORIGIN}" ]]; then
  CHECK_URL="${LEMONADE_ORIGIN}/"
else
  CHECK_URL="${ORIGIN}"
fi
if ! curl -fsS -o /dev/null --max-time 3 "${CHECK_URL}"; then
  echo "Warning: ${CHECK_URL} is not responding. The tunnel will still be configured." >&2
fi

tunnel_id() {
  "${CLOUDFLARED}" tunnel list -o json | python3 -c '
import json, sys
name = sys.argv[1]
for tunnel in json.load(sys.stdin):
    deleted = tunnel.get("deleted_at") or ""
    if tunnel.get("name") == name and deleted.startswith("0001"):
        print(tunnel["id"])
        break
' "${TUNNEL_NAME}"
}

TUNNEL_ID="$(tunnel_id || true)"
if [[ -z "${TUNNEL_ID}" ]]; then
  echo "Creating tunnel ${TUNNEL_NAME}"
  "${CLOUDFLARED}" tunnel create "${TUNNEL_NAME}"
  TUNNEL_ID="$(tunnel_id)"
fi

if [[ -z "${TUNNEL_ID}" ]]; then
  echo "Could not find tunnel id for ${TUNNEL_NAME}." >&2
  exit 1
fi

CRED_FILE="${CF_DIR}/${TUNNEL_ID}.json"
if [[ ! -f "${CRED_FILE}" ]]; then
  echo "Tunnel ${TUNNEL_NAME} (${TUNNEL_ID}) has no credentials file at ${CRED_FILE}." >&2
  echo "That tunnel was created somewhere else. Create a new name or copy its credentials here." >&2
  exit 1
fi

mkdir -p "${CF_DIR}"
umask 077
tmp_config="$(mktemp)"
cat > "${tmp_config}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}
ingress:
  - hostname: ${HOSTNAME}
    service: ${ORIGIN}
  - service: http_status:404
EOF
mv "${tmp_config}" "${CONFIG}"
chmod 600 "${CONFIG}"

install_origin_proxy() {
  local unit_path="${HOME}/.config/systemd/user/${PROXY_UNIT}"
  mkdir -p "${HOME}/.config/systemd/user"
  cat > "${unit_path}" <<EOF
[Unit]
Description=Strip browser Origin before forwarding to Lemonade
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${HOME}/llm-origin-proxy.py
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "${PROXY_UNIT}"
  systemctl --user restart "${PROXY_UNIT}"
}

if [[ "${ORIGIN}" == "${PROXY_ORIGIN}" ]]; then
  install_origin_proxy
  UNIT_AFTER="network-online.target ${PROXY_UNIT}"
  UNIT_WANTS="network-online.target ${PROXY_UNIT}"
else
  UNIT_AFTER="network-online.target"
  UNIT_WANTS="network-online.target"
fi

echo "Routing ${HOSTNAME} to tunnel ${TUNNEL_NAME}"
"${CLOUDFLARED}" tunnel route dns --overwrite-dns "${TUNNEL_NAME}" "${HOSTNAME}"

run_foreground() {
  exec "${CLOUDFLARED}" tunnel --config "${CONFIG}" --no-autoupdate run "${TUNNEL_ID}"
}

if [[ "${FOREGROUND}" -eq 1 ]]; then
  echo "Starting tunnel in the foreground. https://${HOSTNAME} -> ${ORIGIN}"
  run_foreground
fi

mkdir -p "${HOME}/.config/systemd/user"
cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=Cloudflare Tunnel for ${HOSTNAME}
After=${UNIT_AFTER}
Wants=${UNIT_WANTS}

[Service]
Type=simple
ExecStart=${CLOUDFLARED} tunnel --config ${CONFIG} --no-autoupdate run ${TUNNEL_ID}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable "${UNIT_NAME}"
# enable --now leaves an already running process on the old config.
systemctl --user restart "${UNIT_NAME}"
systemctl --user --no-pager --full status "${UNIT_NAME}"

echo
if [[ "${ORIGIN}" == "${PROXY_ORIGIN}" ]]; then
  echo "https://${HOSTNAME} proxies to ${PROXY_ORIGIN}, which forwards to ${LEMONADE_ORIGIN}"
else
  echo "https://${HOSTNAME} proxies to ${ORIGIN}"
fi
echo "Config: ${CONFIG}"
echo "Logs:   journalctl --user -u ${UNIT_NAME} -f"

if [[ "$(loginctl show-user "${USER}" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
  echo
  echo "This user service stops when your login session ends."
  echo "Keep it running after logout with: sudo loginctl enable-linger ${USER}"
fi
