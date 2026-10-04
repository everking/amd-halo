# amd-halo

Reproducible setup for the AMD Ryzen AI Developer Platform (rex).

## System

| Property | Value |
|----------|-------|
| CPU | AMD RYZEN AI MAX+ 395 w/ Radeon 8060S |
| RAM | 128 GB (125 Gi usable) |
| Disk | 1.9 TB NVMe (nvme0n1) |
| Kernel | 7.2.7+rex-amd64 (AMD custom kernel) |
| OS | AMD Ryzen AI Developer Platform (rex) — Debian-based |
| WiFi | MEDIATEK MT7925 (RZ717) Wi-Fi 7 |
| Audio | AMD/ATI Radeon High Definition Audio |

## Quick start

```bash
# 1. Clone this repo
git clone git@github.com:everking/amd-halo.git ~/dev/amd-halo
cd ~/dev/amd-halo

# 2. Run the setup script
chmod +x setup.sh
./setup.sh

# 3. Follow the "Next steps" printed by the script
```

The script is **idempotent** — re-running it is safe.

## Manual setup

If you prefer to set things up manually, follow the steps below.

### 1. System packages

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential curl wget git gnupg software-properties-common \
  python3 python3-pip python3-venv openssl
```

### 2. Firmware

```bash
sudo apt-get install -y \
  amd64-microcode \
  firmware-amd-graphics \
  firmware-mediatek \
  firmware-realtek \
  fwupd-amd-signed \
  systemd-boot-efi-amd64-signed
```

### 3. Kernel

The current kernel is `7.2.7+rex-amd64`. On a fresh install:

```bash
sudo apt-get install -y linux-image-amd64
```

### 4. LM Studio

#### Download and install

```bash
# Get the latest release
LM_STUDIO_URL="$(curl -fsSL https://api.github.com/repos/LMStudio-ai/lm-studio/releases/latest \
  | grep -E '"browser_download_url".*x86_64\.AppImage"' \
  | head -1 \
  | sed 's/.*"browser_download_url": "\(.*\)".*/\1/')"

wget -O /tmp/lm-studio.AppImage "$LM_STUDIO_URL"
sudo mkdir -p /opt/lm-studio
sudo mv /tmp/lm-studio.AppImage /opt/lm-studio/lm-studio.AppImage
sudo chmod +x /opt/lm-studio/lm-studio.AppImage
sudo ln -sf /opt/lm-studio/lm-studio.AppImage /usr/local/bin/lm-studio
```

#### Start the inference server

```bash
# Option A: Use the bundled lms CLI
lms server start --bind 0.0.0.0 --port 13305

# Option B: Use the helper script
~/bin/lm-studio-start.sh

# Option C: Open the GUI, load a model, and the server starts automatically
lm-studio
```

#### Configure LM Studio settings

Create `~/.lmstudio/settings.json`:

```json
{
  "language": "en",
  "downloadsFolder": "/home/eric/.lmstudio/models",
  "defaultContextLength": { "type": "custom", "value": 65536 },
  "useLlamaCppEngineProtocolRuntime3": true
}
```

### 5. Pi coding agent

#### Install

```bash
npm install -g @earendil-works/pi-coding-agent
```

#### Create config

```bash
mkdir -p ~/.pi/agent

# settings.json
cat > ~/.pi/agent/settings.json <<'EOF'
{
  "defaultProvider": "huggingface",
  "defaultModel": "openai/gpt-oss-120b"
}
EOF

# models.json (LM Studio provider)
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
          "maxTokens": 16384
        },
        {
          "id": "google/gemma-4-31b",
          "name": "Gemma 4 31B",
          "reasoning": false,
          "input": ["text", "image"],
          "contextWindow": 131072,
          "maxTokens": 16384
        },
        {
          "id": "lemonade/qwen3-coder-30b-a3b-instruct",
          "name": "Qwen3 Coder 30B A3B",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384
        },
        {
          "id": "unsloth/qwen3-coder-30b-a3b-instruct",
          "name": "Qwen3 Coder 30B A3B (Unsloth)",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384
        },
        {
          "id": "gpt-oss-20b",
          "name": "GPT-OSS 20B",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384
        },
        {
          "id": "gpt-oss-120b",
          "name": "GPT-OSS 120B",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384
        },
        {
          "id": "q4_k_m",
          "name": "GPT-OSS 120B (q4_k_m)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 16384
        },
        {
          "id": "qwen/qwen3.6-35b-a3b",
          "name": "Qwen3.6 35B A3B",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 131072,
          "maxTokens": 16384
        }
      ]
    }
  }
}
EOF
```

#### Use

```bash
pi                  # Start interactive mode
/reload             # Reload config after changes
/settings           # Change common preferences
```

### 6. Python packages

```bash
cd ~/dev/amd-halo
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install aiofiles annotated-types anyio APScheduler argcomplete attrs \
  autocommand av babel bcrypt beautifulsoup4 blosc boto3 botocore \
  Bottleneck Brotli build certifi chardet charset-normalizer click \
  cloudpickle colorama contourpy crit cryptography distro docstring_parser \
  fastapi feedparser filelock filetype flatbuffers fonttools fsspec \
  gitpython h11 httpcore httpx idna jiter jmespath json5 jsonschema \
  jsonschema-specifications litellm lxml markdown markdown-it-py markupsafe \
  mdurl mpmath msgpack natsort networkx numpy openai orjson packaging \
  pandas pillow pip platformdirs prometheus_client propcache protobuf \
  proto-plus pyarrow pyasn1 pyasn1-modules pycryptodome pydantic \
  pydantic-core pydantic-settings pygments pyjwt pymongo pyparsing \
  pyperclip python-dateutil python-dotenv python-json-logger pytz \
  pyyaml rapidfuzz referencing regex requests requests-toolbelt rich \
  rpds-py rsa s3transfer safetensors scipy semantic-version setuptools \
  shellingham simplejson six sniffio starlette sympy tensorboard \
  tensorboard-data-server termcolor text-generation tiktoken tinycss2 \
  tokenizers torch torchaudio torchvision tornado tqdm typeguard \
  typing_extensions tzlocal uc-micro-py ufoLib2 unicodedata2 urllib3 \
  userpath uvicorn uvloop webencodings wheel wsproto xdg zict zopfli

# AMD debug tools (custom)
pip install amd-debug-tools
```

### 7. Cloudflare Tunnel

#### Install cloudflared

```bash
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
rm /tmp/cloudflared.deb
```

#### Login (first time only)

```bash
cloudflared tunnel login
# This opens a browser to authenticate. The cert is saved to ~/.cloudflared/cert.pem
```

#### Create a tunnel for LLM services

```bash
# Use the helper script
~/bin/cloudflared-llm.sh llm 13305

# Or manually:
cloudflared tunnel create llm
# (Note the tunnel ID)
cloudflared tunnel route dns llm llm.m634.dev
# (Create the config file at ~/.cloudflared/config-llm.yml)
# (Start the systemd user service)
```

### 8. Remote Desktop (GNOME RDP)

```bash
sudo apt-get install -y gnome-remote-desktop
~/bin/install-remote-desktop.sh
```

This sets up headless RDP on port 3389 with auto-generated credentials.

### 9. Shell profile

Add to `~/.profile`:

```bash
# LM Studio CLI
export PATH="$PATH:/home/eric/.lmstudio/bin"

# Custom scripts
if [ -d "$HOME/bin" ]; then
  PATH="$HOME/bin:$PATH"
fi

# Hugging Face token
if [[ -f ~/.env ]]; then
  source ~/.env
fi
```

Create `~/.env`:

```bash
HF_TOKEN=hf_your_token_here
```

### 10. Enable user linger (services survive logout)

```bash
sudo loginctl enable-linger $USER
```

## Custom scripts

All custom scripts live in `~/bin/`:

| Script | Purpose |
|--------|---------|
| `lm-studio-start.sh` | Start the LM Studio inference server |
| `pull-qwen3-coder-next.sh` | Download Qwen3-Coder-Next model (~48 GB) |
| `cloudflared-login.sh` | Authenticate cloudflared with Cloudflare |
| `cloudflared-llm.sh` | Create/reuse a Cloudflare Tunnel for LLM services |
| `llm-origin-proxy.py` | HTTP proxy that strips Origin headers and adds web search support |
| `install-remote-desktop.sh` | Install and configure headless GNOME RDP |

## Syncing config across machines

To avoid maintaining config on multiple machines, point pi to a synced directory:

```bash
# On both machines, set this in your shell profile:
export PI_CODING_AGENT_DIR=/path/to/your/synced/dotfiles/pi-agent
```

Then sync that directory with your preferred tool (git, syncthing, iCloud, etc.).

## Model downloads

| Model | Size | Notes |
|-------|------|-------|
| Qwen3-Coder-Next-GGUF (MXFP4 MoE) | ~48 GB | `~/bin/pull-qwen3-coder-next.sh` |
| Gemma 4 31B | ~20 GB | Via LM Studio GUI |
| Qwen3 Coder 30B A3B | ~18 GB | Via LM Studio GUI |

## Troubleshooting

### LM Studio server won't start

```bash
# Check if port 13305 is in use
ss -tlnp | grep 13305

# Kill any existing process
fuser -k 13305/tcp

# Restart
~/bin/lm-studio-start.sh
```

### Pi can't connect to LM Studio

```bash
# Verify the server is running
curl http://127.0.0.1:13305/v1/models

# Check models.json baseUrl matches
cat ~/.pi/agent/models.json | grep baseUrl
```

### Cloudflare tunnel not working

```bash
# Check tunnel status
cloudflared tunnel list

# Check logs
journalctl --user -u cloudflared-llm-llm.service -f

# Verify DNS record
cloudflared tunnel info llm
```

### RDP won't connect

```bash
# Check if port 3389 is open
ss -tlnp | grep 3389

# Check service status
systemctl --user status gnome-remote-desktop-headless.service

# Get password from file
cat ~/.local/share/gnome-remote-desktop/rdp-password
```
