#!/usr/bin/env bash
# ============================================================================
# amd-halo — Full system setup script
# ============================================================================
#
# Re-creates the current environment from scratch on a fresh install.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# The script is idempotent — re-running is safe.
#
# Manual override flags (set before running):
#   SKIP_LM_STUDIO=1     — skip LM Studio install
#   SKIP_PI=1            — skip pi agent install
#   SKIP_PYTHON=1        — skip pip packages
#   SKIP_CLOUDFLARED=1   — skip cloudflared install
#   SKIP_RDP=1           — skip remote desktop install
#   SKIP_MODELS=1        — skip model downloads
#   SKIP_GIT_CONFIG=1    — skip git config
#
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Helpers ─────────────────────────────────────────────────────────────────

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Some steps need sudo. You'll be prompted when needed."
  fi
}

needs_sudo() {
  [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null
}

sudo_if_needed() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ── 0. Pre-flight ──────────────────────────────────────────────────────────

log "=== Pre-flight checks ==="

if [[ "$(uname -m)" != "x86_64" ]]; then
  err "This script is for x86_64 (AMD Ryzen AI Developer Platform)."
  exit 1
fi

# ── 1. System packages ─────────────────────────────────────────────────────

log "=== Installing system packages ==="

sudo_if_needed apt-get update
sudo_if_needed apt-get install -y \
  build-essential \
  curl \
  wget \
  git \
  gnupg \
  software-properties-common \
  python3 python3-pip python3-venv \
  openssl \
  cloudflared \
  libnvidia-gl-575 2>/dev/null || true   # may not exist on all systems

# Firmware (AMD/ATI, MediaTek, Realtek)
log "Ensuring firmware packages..."
sudo_if_needed apt-get install -y \
  amd64-microcode \
  firmware-amd-graphics \
  firmware-mediatek \
  firmware-realtek \
  fwupd-amd-signed \
  systemd-boot-efi-amd64-signed

# ── 2. Kernel ───────────────────────────────────────────────────────────────

log "=== Kernel ==="

log "Current kernel: $(uname -r)"
log "Kernel cmdline: $(cat /proc/cmdline)"

# On a fresh install, make sure the correct kernel is installed
sudo_if_needed apt-get install -y linux-image-amd64

# ── 3. LM Studio ────────────────────────────────────────────────────────────

if [[ "${SKIP_LM_STUDIO:-0}" != "1" ]]; then
  log "=== LM Studio ==="

  if command -v lmstudio &>/dev/null || [[ -d /opt/lm-studio ]]; then
    log "LM Studio already installed, skipping."
  else
    log "Downloading LM Studio..."

    # Detect latest release
    LM_STUDIO_URL="$(curl -fsSL https://api.github.com/repos/LMStudio-ai/lm-studio/releases/latest \
      | grep -E '"browser_download_url".*x86_64\.AppImage"' \
      | head -1 \
      | sed 's/.*"browser_download_url": "\(.*\)".*/\1/')"

    if [[ -z "$LM_STUDIO_URL" ]]; then
      err "Could not find LM Studio download URL."
      exit 1
    fi

    log "URL: $LM_STUDIO_URL"

    wget -O /tmp/lm-studio.AppImage "$LM_STUDIO_URL"
    chmod +x /tmp/lm-studio.AppImage

    # Install to /opt
    sudo_if_needed mkdir -p /opt/lm-studio
    sudo_if_needed mv /tmp/lm-studio.AppImage /opt/lm-studio/lm-studio.AppImage
    sudo_if_needed chmod +x /opt/lm-studio/lm-studio.AppImage

    # Create a launcher symlink
    sudo_if_needed ln -sf /opt/lm-studio/lm-studio.AppImage /usr/local/bin/lm-studio

    log "LM Studio installed to /opt/lm-studio/"

    # Create the start script for the LM Studio server
    mkdir -p ~/bin
    cat > ~/bin/lm-studio-start.sh <<'SCRIPT'
#!/usr/bin/env bash
# Start the LM Studio inference server (lms)
# Usage: lm-studio-start.sh
#
# If lms CLI is not installed, this script tries to install it.
set -euo pipefail

if ! command -v lms &>/dev/null; then
  # Try to install lms via LM Studio's bundled CLI
  if [[ -x /opt/lm-studio/lms ]]; then
    /opt/lm-studio/lms server start --bind 0.0.0.0 --port 13305
  else
    echo "lms CLI not found. Start LM Studio GUI first, then run this script."
    echo "Or install lms: https://lmstudio.ai/docs/cli"
    exit 1
  fi
else
  lms server start --bind 0.0.0.0 --port 13305
fi
SCRIPT
    chmod +x ~/bin/lm-studio-start.sh
    log "Created ~/bin/lm-studio-start.sh"
  fi
else
  warn "Skipping LM Studio install."
fi

# ── 3b. LM Studio Optimization (Strix Halo) ──────────────────────────────

if [[ "${SKIP_LM_STUDIO:-0}" != "1" ]]; then
  log "=== LM Studio Optimization ==="

  # Helper to find lms CLI
  LMS=""
  for candidate in \
    "$HOME/.lmstudio/bin/lms" \
    /opt/lm-studio/lms \
    /opt/lm-studio/bin/lms \
    "$HOME/bin/lms"; do
    if [[ -x "$candidate" ]]; then
      LMS="$candidate"
      break
    fi
  done

  if [[ -z "$LMS" ]]; then
    warn "lms CLI not found. Optimization skipped (run after LM Studio is installed)."
  else
    log "Found lms at $LMS"

    # 1. Set Vulkan as default GGUF engine
    log "Setting Vulkan GGUF engine..."
    BACKEND_PREF="$HOME/.lmstudio/.internal/backend-preferences-v1.json"
    if [[ -f "$BACKEND_PREF" ]]; then
      if grep -q 'vulkan-avx2' "$BACKEND_PREF" 2>/dev/null; then
        log "Vulkan backend already set."
      else
        # Replace avx2 with vulkan-avx2 in the preferences file
        sed -i 's/llama.cpp-linux-x86_64-avx2/llama.cpp-linux-x86_64-vulkan-avx2/g' "$BACKEND_PREF"
        log "Updated backend-preferences-v1.json → vulkan-avx2"
      fi
    else
      log "No backend-preferences-v1.json found — creating..."
      mkdir -p "$HOME/.lmstudio/.internal"
      cat > "$BACKEND_PREF" <<'EOF'
{
  "gguf": {
    "backend": "llama.cpp-linux-x86_64-vulkan-avx2"
  }
}
EOF
      log "Created $BACKEND_PREF"
    fi

    # 2. Set default context length to 65536
    log "Setting default context length to 65536..."
    LM_STUDIO_SETTINGS="$HOME/.lmstudio/settings.json"
    if [[ -f "$LM_STUDIO_SETTINGS" ]]; then
      if grep -q '"defaultContextLength"' "$LM_STUDIO_SETTINGS" 2>/dev/null; then
        # Update existing value
        if grep -q '"value": 65536' "$LM_STUDIO_SETTINGS" 2>/dev/null; then
          log "Context length already 65536."
        else
          sed -i 's/"defaultContextLength":.*"value": *[0-9]*/"defaultContextLength": { "type": "custom", "value": 65536 }/' "$LM_STUDIO_SETTINGS"
          log "Updated defaultContextLength to 65536."
        fi
      else
        # Add the setting
        sed -i '/}/i\  "defaultContextLength": { "type": "custom", "value": 65536 },' "$LM_STUDIO_SETTINGS"
        log "Added defaultContextLength to settings.json."
      fi
    else
      log "No settings.json — creating minimal one..."
      cat > "$LM_STUDIO_SETTINGS" <<'EOF'
{
  "language": "en",
  "downloadsFolder": "/home/eric/.lmstudio/models",
  "defaultContextLength": { "type": "custom", "value": 65536 },
  "useLlamaCppEngineProtocolRuntime3": true
}
EOF
    fi

    # 3. Set server port to 1234 (standard for this setup)
    log "Ensuring server port is 1234..."
    if [[ ! -f "$HOME/bin/lm-studio-start.sh" ]]; then
      cat > "$HOME/bin/lm-studio-start.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Start the LM Studio inference server (lms)
# Usage: lm-studio-start.sh
set -euo pipefail

if ! command -v lms &>/dev/null; then
  if [[ -x /opt/lm-studio/lms ]]; then
    /opt/lm-studio/lms server start --bind 0.0.0.0 --port 13305
  else
    echo "lms CLI not found."
    exit 1
  fi
else
  lms server start --bind 0.0.0.0 --port 1234
fi
SCRIPT
      chmod +x "$HOME/bin/lm-studio-start.sh"
      log "Created ~/bin/lm-studio-start.sh (port 1234)."
    fi

    log "Optimization complete."
    log ""
    log "To apply Vulkan + optimized load on the current session:"
    log "  $LMS server stop"
    log "  $LMS server start --bind 0.0.0.0 --port 1234"
    log "  $LMS load qwen/qwen3.6-35b-a3b --gpu max -c 65536 --parallel 2"
    log ""
    log "Verify:"
    log "  $LMS runtime ls"
    log "  $LMS ps"
    log "  pgrep -af llama-server | grep vulkan-avx2"
  fi
else
  warn "Skipping LM Studio optimization."
fi

# ── 4. Pi Coding Agent ─────────────────────────────────────────────────────

if [[ "${SKIP_PI:-0}" != "1" ]]; then
  log "=== Pi Coding Agent ==="

  if [[ -x ~/.pi/agent/bin/pi ]]; then
    log "Pi already installed ($(pi --version 2>/dev/null || echo 'unknown version'), skipping."
  else
    log "Installing pi coding agent..."

    # Install via npm (pi is distributed as an npm package)
    npm install -g @earendil-works/pi-coding-agent 2>/dev/null || {
      # Fallback: install from release tarball
      log "npm install failed, trying manual install..."
      PI_VERSION="1.0.2"
      PI_URL="https://github.com/earendil-works/pi-coding-agent/releases/download/v${PI_VERSION}/pi-coding-agent-${PI_VERSION}.tar.gz"
      mkdir -p /tmp/pi-install
      wget -q -O /tmp/pi-install/pi.tar.gz "$PI_URL" 2>/dev/null || {
        err "Could not download pi. Install manually: npm install -g @earendil-works/pi-coding-agent"
        exit 1
      }
      tar xzf /tmp/pi-install/pi.tar.gz -C /tmp/pi-install/
      sudo_if_needed cp -r /tmp/pi-install/* /usr/local/lib/pi/
      sudo_if_needed ln -sf /usr/local/lib/pi/bin/pi /usr/local/bin/pi
      rm -rf /tmp/pi-install
    }

    log "Pi installed."
  fi
fi

# ── 5. Python packages ─────────────────────────────────────────────────────

if [[ "${SKIP_PYTHON:-0}" != "1" ]]; then
  log "=== Python packages ==="

  # Create a virtual environment for the system
  if [[ ! -d ~/dev/amd-halo/.venv ]]; then
    log "Creating Python venv at ~/dev/amd-halo/.venv..."
    python3 -m venv ~/dev/amd-halo/.venv
  fi

  source ~/dev/amd-halo/.venv/bin/activate

  # Core packages (mirrors what's currently installed)
  pip install --upgrade pip
  pip install \
    aiofiles \
    annotated-types \
    anyio \
    APScheduler \
    argcomplete \
    attrs \
    autocommand \
    av \
    babel \
    bcrypt \
    beautifulsoup4 \
    blosc \
    boto3 \
    botocore \
    Bottleneck \
    Brotli \
    build \
    certifi \
    chardet \
    charset-normalizer \
    click \
    cloudpickle \
    colorama \
    contourpy \
    crit \
    cryptography \
    distro \
    docstring_parser \
    fastapi \
    feedparser \
    filelock \
    filetype \
    flatbuffers \
    fonttools \
    fsspec \
    gitpython \
    google-ai-generativelanguage \
    google-api-core \
    google-auth \
    google-cloud-aiplatform \
    google-cloud-bigquery \
    google-cloud-core \
    google-cloud-resource-management \
    google-cloud-storage \
    google-crc32c \
    google-resumable-media \
    googleapis-common-protos \
    grpcio \
    grpcio-status \
    h11 \
    h2 \
    hpack \
    httpcore \
    httptools \
    httpx \
    hyperframe \
    idna \
    jiter \
    jmespath \
    json5 \
    jsonschema \
    jsonschema-specifications \
    litellm \
    lxml \
    markdown \
    markdown-it-py \
    markupsafe \
    mdurl \
    mpmath \
    msgpack \
    natsort \
    networkx \
    numpy \
    openai \
    orjson \
    packaging \
    pandas \
    pillow \
    pip \
    platformdirs \
    prometheus_client \
    propcache \
    protobuf \
    proto-plus \
    pyarrow \
    pyasn1 \
    pyasn1-modules \
    pycryptodome \
    pydantic \
    pydantic-core \
    pydantic-settings \
    pygments \
    pyjwt \
    pymongo \
    pyobjc-core \
    pyobjc-framework-Cocoa \
    pyparsing \
    pyperclip \
    python-dateutil \
    python-dotenv \
    python-json-logger \
    pytz \
    pyyaml \
    rapidfuzz \
    referencing \
    regex \
    requests \
    requests-toolbelt \
    rich \
    rpds-py \
    rsa \
    s3transfer \
    safetensors \
    scipy \
    semantic-version \
    setuptools \
    shellingham \
    simplejson \
    six \
    sniffio \
    starlette \
    sympy \
    tensorboard \
    tensorboard-data-server \
    termcolor \
    text-generation \
    tiktoken \
    tinycss2 \
    tokenizers \
    torch \
    torchaudio \
    torchvision \
    tornado \
    tqdm \
    typeguard \
    typing_extensions \
    tzlocal \
    uc-micro-py \
    ufoLib2 \
    unicodedata2 \
    urllib3 \
    userpath \
    uvicorn \
    uvloop \
    webencodings \
    wheel \
    wsproto \
    xdg \
    zict \
    zopfli

  # AMD debug tools (custom package)
  pip install amd-debug-tools

  deactivate
  log "Python packages installed."
fi

# ── 6. Cloudflare Tunnel ───────────────────────────────────────────────────

if [[ "${SKIP_CLOUDFLARED:-0}" != "1" ]]; then
  log "=== Cloudflare Tunnel ==="

  if command -v cloudflared &>/dev/null; then
    log "cloudflared already installed ($(cloudflared --version | head -1))."
  else
    log "Installing cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
      -o /tmp/cloudflared.deb
    sudo_if_needed dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
    log "cloudflared installed."
  fi

  # Login (user must provide token)
  if [[ ! -f ~/.cloudflared/cert.pem ]]; then
    warn "No Cloudflare origin cert found at ~/.cloudflared/cert.pem"
    warn "Run manually: cloudflared tunnel login"
  fi
fi

# ── 7. Remote Desktop (GNOME RDP) ──────────────────────────────────────────

if [[ "${SKIP_RDP:-0}" != "1" ]]; then
  log "=== Remote Desktop ==="

  if ! command -v grdctl &>/dev/null; then
    warn "gnome-remote-desktop not found."
    warn "Install manually: sudo apt-get install -y gnome-remote-desktop"
    warn "Then run: ~/bin/install-remote-desktop.sh"
  else
    log "gnome-remote-desktop is installed."
    log "Run ~/bin/install-remote-desktop.sh to configure headless RDP."
  fi
fi

# ── 8. Copy custom scripts ─────────────────────────────────────────────────

log "=== Installing custom scripts ==="

mkdir -p ~/bin

# lm-studio-start.sh (already created above if LM Studio was installed)

# cloudflared-login.sh
cat > ~/bin/cloudflared-login.sh <<'SCRIPT'
#!/usr/bin/env bash
# Authenticate cloudflared with Cloudflare.
# Run this once to obtain an origin certificate.
set -euo pipefail
cloudflared tunnel login
SCRIPT
chmod +x ~/bin/cloudflared-login.sh

# cloudflared-llm.sh
cat > ~/bin/cloudflared-llm.sh <<'SCRIPT'
#!/usr/bin/env bash
# Create/reuse a Cloudflare Tunnel for LLM services.
# Usage: cloudflared-llm.sh <prefix> [port|url] [--foreground]
#
# Examples:
#   cloudflared-llm.sh llm 13305
#   cloudflared-llm.sh ai-proxy https://api.example.com --foreground
set -euo pipefail

HOSTNAME_BASE="m634.dev"
LEMONADE_ORIGIN="http://127.0.0.1:13305"
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
      exit 2 ;;
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
      shift ;;
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

if ! command -v cloudflared &>/dev/null; then
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
SCRIPT
chmod +x ~/bin/cloudflared-llm.sh

# llm-origin-proxy.py
cp -n /dev/null ~/llm-origin-proxy.py 2>/dev/null || true
# (The proxy script is large; see README for instructions to copy it)

# pull-qwen3-coder-next.sh
cat > ~/bin/pull-qwen3-coder-next.sh <<'SCRIPT'
#!/usr/bin/env bash
# Download Qwen3-Coder-Next into Lemonade.
# Checkpoint: unsloth/Qwen3-Coder-Next-GGUF:Qwen3-Coder-Next-MXFP4_MOE.gguf
set -euo pipefail

MODEL="Qwen3-Coder-Next-GGUF"

if ! command -v lemonade &>/dev/null; then
  echo "lemonade is not on PATH." >&2
  exit 1
fi

if ! lemonade status &>/dev/null; then
  echo "Lemonade is not running. Start it with: sudo systemctl start lemond" >&2
  exit 1
fi

already_downloaded() {
  lemonade list --downloaded | awk 'NR > 2 && $2 == "Yes" { print $1 }' | grep -qx "${MODEL}"
}

if already_downloaded; then
  echo "${MODEL} is already downloaded."
  lemonade list --downloaded
  exit 0
fi

echo "Downloading ${MODEL} from Hugging Face (about 48 GB)."
echo "Checkpoint: unsloth/Qwen3-Coder-Next-GGUF:Qwen3-Coder-Next-MXFP4_MOE.gguf"
lemonade pull "${MODEL}"

if ! already_downloaded; then
  echo "Pull finished, but ${MODEL} is not in the downloaded list." >&2
  lemonade list --downloaded >&2
  exit 1
fi

echo "${MODEL} is downloaded and listed with the other local models."
lemonade list --downloaded
SCRIPT
chmod +x ~/bin/pull-qwen3-coder-next.sh

# install-remote-desktop.sh
cat > ~/bin/install-remote-desktop.sh <<'SCRIPT'
#!/usr/bin/env bash
# Install GNOME Remote Desktop and enable headless RDP.
# Usage: install-remote-desktop.sh
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
SCRIPT
chmod +x ~/bin/install-remote-desktop.sh

log "Custom scripts installed to ~/bin/"

# ── 9. Shell profile ───────────────────────────────────────────────────────

log "=== Shell profile ==="

# Install zsh
if ! command -v zsh &>/dev/null; then
  log "Installing zsh..."
  sudo_if_needed apt-get install -y zsh
fi

# Install oh-my-zsh (non-interactive)
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  log "Installing oh-my-zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended 2>/dev/null || true
fi

# ── .profile (sourced by login shells: bash, zsh, etc.) ─────────────────

PROFILE="$HOME/.profile"
if [[ ! -f "$PROFILE" ]]; then
  touch "$PROFILE"
fi

# Add ~/.local/bin to PATH (if not already present)
if ! grep -q '.local/bin' "$PROFILE" 2>/dev/null; then
  echo '' >> "$PROFILE"
  echo '# Local bin directory' >> "$PROFILE"
  echo 'if [ -d "$HOME/.local/bin" ]; then PATH="$HOME/.local/bin:$PATH"; fi' >> "$PROFILE"
fi

# Add ~/bin to PATH (if not already present)
if ! grep -q 'HOME/bin' "$PROFILE" 2>/dev/null; then
  echo '' >> "$PROFILE"
  echo '# Custom scripts' >> "$PROFILE"
  echo 'if [ -d "$HOME/bin" ]; then PATH="$HOME/bin:$PATH"; fi' >> "$PROFILE"
fi

# Add LM Studio bin to PATH (if not already present)
if ! grep -q 'lmstudio/bin' "$PROFILE" 2>/dev/null; then
  echo '' >> "$PROFILE"
  echo '# LM Studio CLI' >> "$PROFILE"
  echo 'export PATH="$PATH:/home/eric/.lmstudio/bin"' >> "$PROFILE"
fi

# Source HF_TOKEN from ~/.env (if not already present)
if ! grep -q 'HF_TOKEN' "$PROFILE" 2>/dev/null; then
  echo '' >> "$PROFILE"
  echo '# Hugging Face token' >> "$PROFILE"
  echo 'if [[ -f ~/.env ]]; then source ~/.env; fi' >> "$PROFILE"
fi

# ── .zshrc (sourced by interactive zsh shells) ──────────────────────────

ZSHRC="$HOME/.zshrc"
if [[ ! -f "$ZSHRC" ]]; then
  touch "$ZSHRC"
fi

# Source .profile so zsh gets the same variables as bash
if ! grep -q 'source ~/.profile' "$ZSHRC" 2>/dev/null; then
  echo '' >> "$ZSHRC"
  echo '# Source .profile for shared variables (PATH, HF_TOKEN, etc.)'
  echo 'if [[ -f "$HOME/.profile" ]]; then source "$HOME/.profile"; fi' >> "$ZSHRC"
fi

# Create ~/.env if it doesn't exist
HF_TOKEN_FILE="$HOME/.env"
if [[ ! -f "$HF_TOKEN_FILE" ]]; then
  echo "# Hugging Face token" > "$HF_TOKEN_FILE"
  chmod 600 "$HF_TOKEN_FILE"
fi
if ! grep -q 'HF_TOKEN=' "$HF_TOKEN_FILE" 2>/dev/null; then
  echo 'HF_TOKEN=hf_YOUR_TOKEN_HERE' >> "$HF_TOKEN_FILE"
fi

log "Shell profile updated (.profile + .zshrc)."

# ── 10. Pi configuration ───────────────────────────────────────────────────

log "=== Pi configuration ==="

# Create the user-level config directory
mkdir -p ~/.pi/agent

# settings.json
if [[ ! -f ~/.pi/agent/settings.json ]]; then
  cat > ~/.pi/agent/settings.json <<'EOF'
{
  "lastChangelogVersion": "1.0.2",
  "defaultProvider": "huggingface",
  "defaultModel": "openai/gpt-oss-120b"
}
EOF
fi

# models.json (LM Studio provider)
if [[ ! -f ~/.pi/agent/models.json ]]; then
  cat > ~/.pi/agent/models.json <<'EOF'
{
  "providers": {
    "lmstudio": {
      "name": "LM Studio",
      "baseUrl": "http://127.0.0.1:1234/v1",
      "api": "openai-completions",
      "apiKey": "lm-studio",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "supportsLongCacheRetention": false,
        "sendSessionAffinityHeaders": false,
        "maxTokensField": "max_tokens"
      },
      "models": [
        {
          "id": "qwen/qwen3-coder-next",
          "name": "Qwen3 Coder Next",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "google/gemma-4-31b",
          "name": "Gemma 4 31B",
          "reasoning": false,
          "input": ["text", "image"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "lemonade/qwen3-coder-30b-a3b-instruct",
          "name": "Qwen3 Coder 30B A3B",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "unsloth/qwen3-coder-30b-a3b-instruct",
          "name": "Qwen3 Coder 30B A3B (Unsloth)",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "gpt-oss-20b",
          "name": "GPT-OSS 20B",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "gpt-oss-120b",
          "name": "GPT-OSS 120B",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "q4_k_m",
          "name": "GPT-OSS 120B (q4_k_m)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "qwen/qwen3.6-35b-a3b",
          "name": "Qwen3.6 35B A3B",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
EOF
fi

# lmstudio settings.json
LM_STUDIO_DIR="$HOME/.lmstudio"
if [[ ! -d "$LM_STUDIO_DIR" ]]; then
  mkdir -p "$LM_STUDIO_DIR"
fi
if [[ ! -f "$LM_STUDIO_DIR/settings.json" ]]; then
  # Create a minimal settings file
  cat > "$LM_STUDIO_DIR/settings.json" <<'EOF'
{
  "language": "en",
  "downloadsFolder": "/home/eric/.lmstudio/models",
  "defaultContextLength": {
    "type": "custom",
    "value": 65536
  },
  "useLlamaCppEngineProtocolRuntime3": true
}
EOF
fi

log "Pi config created at ~/.pi/agent/"

# ── 11. LM Studio home pointer ─────────────────────────────────────────────

if [[ ! -f "$HOME/.lmstudio-home-pointer" ]]; then
  echo "$HOME/.lmstudio" > "$HOME/.lmstudio-home-pointer"
fi

# ── 12. Git config ─────────────────────────────────────────────────────────

if [[ "${SKIP_GIT_CONFIG:-0}" != "1" ]]; then
  log "=== Git config ==="

  if [[ -z "$(git config --global user.name 2>/dev/null)" ]]; then
    warn "Set your git identity:"
    echo "  git config --global user.name 'Your Name'"
    echo "  git config --global user.email 'you@example.com'"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
log "=== Setup complete ==="
echo ""
echo "Next steps:"
echo ""
echo "  1. LM Studio:"
echo "     - Run: ~/bin/lm-studio-start.sh"
echo "     - Optimize (Vulkan + 64k context):"
echo "       lms load qwen/qwen3.6-35b-a3b --gpu max -c 65536 --parallel 2"
echo "     - See LM-Studio-Optimization.md for full tuning guide"
echo ""
echo "  2. Models:"
echo "     - ~/bin/pull-qwen3-coder-next.sh   (Qwen3-Coder-Next, ~48 GB)"
echo ""
echo "  3. Cloudflare Tunnel:"
echo "     - ~/bin/cloudflared-login.sh       (first time only)"
echo "     - ~/bin/cloudflared-llm.sh llm 13305"
echo ""
echo "  4. Remote Desktop:"
echo "     - ~/bin/install-remote-desktop.sh"
echo ""
echo "  5. Pi coding agent:"
echo "     - pi                                (start interactive)"
echo "     - /reload                           (reload config)"
echo ""
echo "  6. Sync config across machines:"
echo "     - export PI_CODING_AGENT_DIR=/path/to/synced/dotfiles/pi-agent"
echo ""
echo "  7. Enable user linger (so services survive logout):"
echo "     - sudo loginctl enable-linger $USER"
echo ""
echo "  8. Commit everything to git:"
echo "     - cd ~/dev/amd-halo && git add -A && git commit -m 'initial setup'"
echo ""
