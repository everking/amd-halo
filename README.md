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

## Repo structure

```
amd-halo/
├── setup.sh              # Idempotent setup script
├── README.md
├── LM-Studio-Optimization.md
├── llm-origin-proxy.py
├── config/
│   ├── logind/99-server-no-suspend.conf  # no idle suspend (server role)
│   ├── lm-studio.service  # systemd user unit (boot without login)
│   ├── pi/
│   │   ├── settings.json  # Pi agent config
│   │   └── models.json    # LM Studio provider + models
│   └── lm-studio/
│       ├── settings.json  # LM Studio preferences (64k context)
│       ├── mcp.json       # MCP server config
│       └── backend-preferences-v1.json  # Vulkan GGUF engine
└── bin/
    ├── install-lm-studio-service.sh  # lm-studio.service + linger
    ├── lm-studio-boot.sh             # daemon + API + model (systemd ExecStart)
    ├── lm-studio-start.sh            # manual start (calls boot script)
    ├── cloudflared-login.sh
    ├── cloudflared-llm.sh
    ├── pull-qwen3-coder-next.sh
    └── install-remote-desktop.sh
```

**Static config files live in `config/`** — they are copied to their target locations during setup.
**Scripts live in `bin/`** — they are copied to `~/bin/` during setup.

## LM Studio Optimization

See **[LM-Studio-Optimization.md](LM-Studio-Optimization.md)** for the full tuning guide applied on 2026-10-03.

### Key changes (also applied by `setup.sh`)

| Setting | Value | Why |
|---------|-------|-----|
| GGUF engine | **Vulkan AVX2** | 8060S GPU offload (no ROCm in LM Studio) |
| Context length | **65536** | Lower RAM pressure & latency |
| GPU offload | **max** (999999 layers) | Full model on GPU |
| Parallel slots | **2** | Reduce KV cache duplication |
| Flash attention | **on** | Faster prefill |

### Verification

```bash
~/.lmstudio/bin/lms server status
~/.lmstudio/bin/lms runtime ls
~/.lmstudio/bin/lms ps
pgrep -af llama-server | grep vulkan-avx2
```

### Standard model load

```bash
~/.lmstudio/bin/lms load qwen/qwen3.6-35b-a3b --gpu max -c 65536 --parallel 2
```

### Boot without login (systemd)

`setup.sh` runs **`bin/install-lm-studio-service.sh`**, which:

1. Installs `~/bin/lm-studio-boot.sh` and `~/bin/lm-studio-start.sh`
2. Installs `~/.config/systemd/user/lm-studio.service` from `config/lm-studio.service`
3. Enables **`loginctl enable-linger`** so user systemd runs at boot (no graphical login)
4. Enables **`lm-studio.service`** on `default.target`

At boot the service runs `lm-studio-boot.sh start`: `lms daemon up`, API on **0.0.0.0:1234**, then loads **`qwen/qwen3.6-35b-a3b`** with the optimized flags unless already loaded. First boot can take several minutes while weights load.

```bash
# Re-run install only (after pulling repo changes):
~/dev/amd-halo/bin/install-lm-studio-service.sh

systemctl --user enable --now lm-studio.service
systemctl --user status lm-studio.service
journalctl --user -u lm-studio.service -b
```

Optional overrides (edit the unit or use `systemctl --user edit lm-studio.service`):

| Variable | Default |
|----------|---------|
| `LMS_PORT` | `1234` |
| `LMS_BIND` | `0.0.0.0` |
| `LMS_MODEL` | `qwen/qwen3.6-35b-a3b` |
| `LMS_LOAD_ARGS` | `--gpu max -c 65536 --parallel 2` |

Cloudflare tunnel units installed via **`cloudflared-llm.sh`** order **after** `lm-studio.service` so the API is up before the tunnel connects.

### Remote server: stay awake (no idle suspend)

For SSH/cloudflared access after **hours or days** without local keyboard/mouse, idle suspend must be off — otherwise LM Studio and the tunnel go down and **nothing on port 1234 wakes the machine**.

`setup.sh` runs **`bin/configure-server-power.sh`**, which:

- Masks systemd `sleep.target` / `suspend.target` / hibernate targets
- Installs `config/logind/99-server-no-suspend.conf` under `/etc/systemd/logind.conf.d/`
- Sets GNOME **sleep-inactive-\*-type** to **`nothing`** (when run with a user D-Bus session)

```bash
~/dev/amd-halo/bin/configure-server-power.sh
```

Inbound traffic (tunnel, curl to :1234) does **not** wake a suspended host; keeping suspend disabled is the reliable approach for this role.

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

### Rebuild from scratch (remote LLM server)

After a fresh OS install, one `./setup.sh` run (with sudo when prompted) covers most of the **always-on server** stack:

| Automated by `setup.sh` | Script / artifact |
|-------------------------|-------------------|
| LM Studio AppImage + Vulkan/config under `~/.lmstudio` | LM Studio section |
| Boot without login: `lm-studio.service` + **linger** | `bin/install-lm-studio-service.sh` |
| **No idle suspend** (LM Studio + tunnel stay up) | `bin/configure-server-power.sh`, `config/logind/99-server-no-suspend.conf` |
| `cloudflared` package + `~/bin/cloudflared-llm.sh` | cloudflared section |

**You still do manually once per machine** (secrets / Cloudflare / large downloads):

1. `~/bin/cloudflared-login.sh` — tunnel credentials
2. `~/bin/cloudflared-llm.sh llm 1234` — writes and **enables** `cloudflared-llm.service` (depends on `lm-studio.service`)
3. Load or download models (e.g. `lms load …`, `~/bin/pull-qwen3-coder-next.sh`)
4. Optional: `~/bin/install-remote-desktop.sh`

Skip flags: `SKIP_SERVER_POWER=1`, `SKIP_LM_STUDIO=1`, `SKIP_CLOUDFLARED=1`, etc. (see header of `setup.sh`).

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
# Option A (recommended on this machine): systemd — survives reboot, no login
~/dev/amd-halo/bin/install-lm-studio-service.sh   # once
systemctl --user start lm-studio.service

# Option B: Use the bundled lms CLI
lms server start --bind 0.0.0.0 --port 1234

# Option C: Use the helper script (same as boot script start)
~/bin/lm-studio-start.sh

# Option D: Open the GUI, load a model, and the server starts automatically
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

cp ~/dev/amd-halo/config/pi/settings.json ~/.pi/agent/
cp ~/dev/amd-halo/config/pi/models.json ~/.pi/agent/
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
~/bin/cloudflared-llm.sh llm 1234

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

The setup installs **zsh** (with oh-my-zsh) and creates a combined profile:

- **`~/.profile`** — sourced by login shells (bash, zsh). Contains all PATH and variable exports.
- **`~/.zshrc`** — sources `~/.profile` so zsh gets the same variables.

#### What gets added to `~/.profile`

```bash
# Local bin directory
if [ -d "$HOME/.local/bin" ]; then PATH="$HOME/.local/bin:$PATH"; fi

# Custom scripts
if [ -d "$HOME/bin" ]; then PATH="$HOME/bin:$PATH"; fi

# LM Studio CLI
export PATH="$PATH:/home/eric/.lmstudio/bin"

# Hugging Face token
if [[ -f ~/.env ]]; then source ~/.env; fi
```

#### Create `~/.env`

```bash
cat > ~/.env <<'EOF'
# Hugging Face token — needed for:
#   • Downloading gated models (e.g. Qwen3-Coder-Next) via huggingface_hub
#   • Accessing models that require explicit permission
# Get one at https://huggingface.co/settings/tokens (free, any scope works)
# Then paste it below: HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
HF_TOKEN=hf_your_token_here
EOF
chmod 600 ~/.env
```

#### Switch to zsh (optional)

```bash
chsh -s $(which zsh)
# Then log out and back in
```

### 10. LM Studio at boot (no login required)

This is installed automatically by **`./setup.sh`** (see **Boot without login** under [LM Studio Optimization](#lm-studio-optimization) above). To configure manually:

```bash
~/dev/amd-halo/bin/install-lm-studio-service.sh
systemctl --user enable --now lm-studio.service
loginctl show-user $USER | grep Linger    # expect Linger=yes
```

Re-install the Cloudflare tunnel unit after LM Studio service exists so ordering is correct:

```bash
~/bin/cloudflared-llm.sh llm 1234
```

## Custom scripts

All custom scripts live in `~/bin/`:

| Script | Purpose |
|--------|---------|
| `configure-server-power.sh` | Disable idle suspend (remote server / always-on LLM) |
| `install-lm-studio-service.sh` | Install `lm-studio.service`, boot scripts, and user linger |
| `lm-studio-boot.sh` | Full headless stack (daemon, API, model); used by systemd |
| `lm-studio-start.sh` | Manual start (calls `lm-studio-boot.sh` when installed) |
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
# Boot service (preferred)
systemctl --user status lm-studio.service
journalctl --user -u lm-studio.service -b --no-pager | tail -50

# Check if port 1234 is in use
ss -tlnp | grep 1234

# Kill any existing process
fuser -k 1234/tcp

# Restart
systemctl --user restart lm-studio.service
# or
~/bin/lm-studio-start.sh
```

### LM Studio not up after reboot

```bash
loginctl show-user $USER | grep Linger          # must be yes for boot without login
systemctl --user is-enabled lm-studio.service
systemctl --user start lm-studio.service
```

### Machine slept / services unreachable remotely

Suspend stops the whole system; the tunnel and API return only after something wakes the hardware (power button, etc.).

```bash
~/dev/amd-halo/bin/configure-server-power.sh
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type   # expect 'nothing'
systemctl is-enabled sleep.target   # expect masked
```

### Pi can't connect to LM Studio

```bash
# Verify the server is running
curl http://127.0.0.1:1234/v1/models

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
