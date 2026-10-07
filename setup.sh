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
#   SKIP_SERVER_POWER=1  — skip disable idle suspend (remote server role)
#
# LM Studio at reboot (no login): setup runs bin/install-lm-studio-service.sh
# (systemd user unit lm-studio.service + loginctl enable-linger).
# Remote server (no idle suspend): setup runs bin/configure-server-power.sh
# unless SKIP_SERVER_POWER=1. See README "Rebuild from scratch".
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

    # Install optimized config files from repo
    REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
    CONFIG_SRC="$REPO_DIR/config/lm-studio"

    # 1. Set Vulkan as default GGUF engine
    log "Setting Vulkan GGUF engine..."
    BACKEND_PREF="$HOME/.lmstudio/.internal/backend-preferences-v1.json"
    if [[ -f "$CONFIG_SRC/backend-preferences-v1.json" ]]; then
      mkdir -p "$HOME/.lmstudio/.internal"
      cp -n "$CONFIG_SRC/backend-preferences-v1.json" "$BACKEND_PREF"
      log "Installed backend-preferences-v1.json → vulkan-avx2"
    fi

    # 2. Install LM Studio settings (only if not present)
    log "Installing LM Studio settings..."
    LM_STUDIO_SETTINGS="$HOME/.lmstudio/settings.json"
    if [[ ! -f "$LM_STUDIO_SETTINGS" ]]; then
      if [[ -f "$CONFIG_SRC/settings.json" ]]; then
        cp "$CONFIG_SRC/settings.json" "$LM_STUDIO_SETTINGS"
        log "Installed settings.json"
      fi
    else
      log "settings.json already exists, skipping."
    fi

    # 3. Install MCP config
    MCP_CONF="$HOME/.lmstudio/mcp.json"
    if [[ ! -f "$MCP_CONF" ]]; then
      if [[ -f "$CONFIG_SRC/mcp.json" ]]; then
        cp "$CONFIG_SRC/mcp.json" "$MCP_CONF"
        log "Installed mcp.json"
      fi
    else
      log "mcp.json already exists, skipping."
    fi

    # Boot scripts + systemd unit: install-lm-studio-service.sh (setup section 11b)

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

  # Install pi config files from repo
  REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
  PI_CONFIG_SRC="$REPO_DIR/config/pi"

  PI_DIR="$HOME/.pi/agent"
  if [[ ! -d "$PI_DIR" ]]; then
    mkdir -p "$PI_DIR"
  fi

  for f in settings.json models.json; do
    TARGET="$PI_DIR/$f"
    if [[ ! -f "$TARGET" ]]; then
      if [[ -f "$PI_CONFIG_SRC/$f" ]]; then
        cp "$PI_CONFIG_SRC/$f" "$TARGET"
        log "Installed $TARGET"
      fi
    else
      log "$TARGET already exists, skipping."
    fi
  done
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
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
    sudo_if_needed dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
    log "cloudflared installed."
  fi

  # Ensure cloudflared-llm.sh is installed
  REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [[ ! -f "$HOME/bin/cloudflared-llm.sh" ]]; then
    if [[ -f "$REPO_DIR/bin/cloudflared-llm.sh" ]]; then
      cp "$REPO_DIR/bin/cloudflared-llm.sh" "$HOME/bin/cloudflared-llm.sh"
      chmod +x "$HOME/bin/cloudflared-llm.sh"
      log "Installed ~/bin/cloudflared-llm.sh"
    fi
  fi
else
  warn "Skipping cloudflared install."
fi

# ── 7. Remote Desktop ──────────────────────────────────────────────────────

if [[ "${SKIP_RDP:-0}" != "1" ]]; then
  log "=== Remote Desktop ==="

  REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [[ ! -f "$HOME/bin/install-remote-desktop.sh" ]]; then
    if [[ -f "$REPO_DIR/bin/install-remote-desktop.sh" ]]; then
      cp "$REPO_DIR/bin/install-remote-desktop.sh" "$HOME/bin/install-remote-desktop.sh"
      chmod +x "$HOME/bin/install-remote-desktop.sh"
      log "Installed ~/bin/install-remote-desktop.sh"
    fi
  fi
else
  warn "Skipping RDP install."
fi

# ── 8. Install bin scripts from repo ───────────────────────────────────────

log "=== Installing bin scripts ==="

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/bin"

for script in "$REPO_DIR/bin/"*; do
  [[ -f "$script" ]] || continue
  fname="$(basename "$script")"
  TARGET="$HOME/bin/$fname"
  if [[ ! -f "$TARGET" ]]; then
    cp "$script" "$TARGET"
    chmod +x "$TARGET"
    log "Installed ~/bin/$fname"
  else
    log "~/bin/$fname already exists, skipping."
  fi
done

# Also copy llm-origin-proxy.py if not already there
if [[ -f "$REPO_DIR/llm-origin-proxy.py" ]]; then
  TARGET="$HOME/bin/llm-origin-proxy.py"
  if [[ ! -f "$TARGET" ]]; then
    cp "$REPO_DIR/llm-origin-proxy.py" "$TARGET"
    chmod +x "$TARGET"
    log "Installed ~/bin/llm-origin-proxy.py"
  fi
fi

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
  cat >> "$HF_TOKEN_FILE" <<'EOF'
# Hugging Face token — needed for:
#   • Downloading gated models (e.g. Qwen3-Coder-Next) via huggingface_hub
#   • Accessing models that require explicit permission
# Get one at https://huggingface.co/settings/tokens (free, any scope works)
# Then paste it below: HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
HF_TOKEN=hf_YOUR_TOKEN_HERE
EOF
fi

log "Shell profile updated (.profile + .zshrc)."

# ── 10. Copy config from repo ──────────────────────────────────────────────

log "=== Copying config from repo ==="

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pi agent config
PI_TARGET="$HOME/.pi/agent"
mkdir -p "$PI_TARGET"
for f in "$REPO_DIR/config/pi/"*; do
  [[ -f "$f" ]] || continue
  fname="$(basename "$f")"
  TARGET="$PI_TARGET/$fname"
  if [[ ! -f "$TARGET" ]]; then
    cp "$f" "$TARGET"
    log "Installed $TARGET"
  else
    log "$TARGET already exists, skipping."
  fi
done

# LM Studio config
LMSTUDIO_TARGET="$HOME/.lmstudio"
mkdir -p "$LMSTUDIO_TARGET"
for f in "$REPO_DIR/config/lm-studio/"*; do
  [[ -f "$f" ]] || continue
  fname="$(basename "$f")"
  TARGET="$LMSTUDIO_TARGET/$fname"
  if [[ ! -f "$TARGET" ]]; then
    cp "$f" "$TARGET"
    log "Installed $TARGET"
  else
    log "$TARGET already exists, skipping."
  fi
done

# LM Studio internal config
LMSTUDIO_INTERNAL="$HOME/.lmstudio/.internal"
mkdir -p "$LMSTUDIO_INTERNAL"
for f in "$REPO_DIR/config/lm-studio/"*; do
  [[ -f "$f" ]] || continue
  fname="$(basename "$f")"
  TARGET="$LMSTUDIO_INTERNAL/$fname"
  if [[ ! -f "$TARGET" ]]; then
    cp "$f" "$TARGET"
    log "Installed $TARGET"
  else
    log "$TARGET already exists, skipping."
  fi
done

# ── 11. Cloudflare tunnel service ──────────────────────────────────────────

log "=== Cloudflare tunnel service ==="

TUNNEL_DIR="$HOME/.config/systemd/user"
mkdir -p "$TUNNEL_DIR"

SRC="$REPO_DIR/config/cloudflared-llm.service"
if [[ ! -f "$TUNNEL_DIR/cloudflared-llm.service" ]]; then
  cp "$SRC" "$TUNNEL_DIR/cloudflared-llm.service"
  log "Installed cloudflared-llm.service"
fi

# ── 11b. LM Studio boot at login / boot (user systemd + linger) ───────────

log "=== LM Studio systemd service ==="
"$REPO_DIR/bin/install-lm-studio-service.sh"

# ── 11c. Remote server: do not suspend on idle ───────────────────────────

if [[ "${SKIP_SERVER_POWER:-0}" != "1" ]]; then
  log "=== Server power (no idle suspend) ==="
  "$REPO_DIR/bin/configure-server-power.sh"
else
  warn "Skipping server power configuration."
fi

# ── 12. Final notes ────────────────────────────────────────────────────────

log "=== Setup complete ==="
echo ""
echo "Next steps:"
echo ""
echo "  1. LM Studio:"
echo "     - Boot service: systemctl --user status lm-studio.service"
echo "     - Manual start: ~/bin/lm-studio-start.sh"
echo "     - Optimize (Vulkan + 64k context):"
echo "       lms load qwen/qwen3.6-35b-a3b --gpu max -c 65536 --parallel 2"
echo "     - See LM-Studio-Optimization.md for full tuning guide"
echo ""
echo "  2. Models:"
echo "     - ~/bin/pull-qwen3-coder-next.sh   (Qwen3-Coder-Next, ~48 GB)"
echo ""
echo "  3. Cloudflare Tunnel:"
echo "     - ~/bin/cloudflared-login.sh       (first time only)"
echo "     - ~/bin/cloudflared-llm.sh llm 1234"
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
echo "  7. LM Studio at reboot: install-lm-studio-service.sh (already run by setup)."
echo "     - Re-run: $REPO_DIR/bin/install-lm-studio-service.sh"
echo "     - Check:  systemctl --user status lm-studio.service"
echo "  8. Server stays awake: configure-server-power.sh (already run by setup)."
echo "     - Re-run: $REPO_DIR/bin/configure-server-power.sh"
echo ""
echo "  9. Commit everything to git:"
echo "     - cd ~/dev/amd-halo && git add -A && git commit -m 'initial setup'"
echo ""
