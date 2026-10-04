#!/usr/bin/env bash
set -euo pipefail

LMSTUDIO_DIR="${HOME}/.lmstudio"
MCP_FILE="${LMSTUDIO_DIR}/mcp.json"
BACKUP_FILE="${MCP_FILE}.backup.$(date +%Y%m%d-%H%M%S)"

echo "==> LM Studio MCP installer"
echo

# ------------------------------------------------------------
# 1. Check Node.js
# ------------------------------------------------------------

if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: Node.js is not installed."
    echo
    echo "Install Node.js 22+ first."
    echo "For example, with nvm:"
    echo
    echo "  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash"
    echo "  source ~/.bashrc"
    echo "  nvm install 22"
    echo "  nvm use 22"
    echo
    exit 1
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"

if [ "$NODE_MAJOR" -lt 22 ]; then
    echo "ERROR: Node.js 22+ is recommended/required by the current Brave MCP."
    echo "Current version: $(node --version)"
    echo
    exit 1
fi

echo "Node.js: $(node --version)"
echo "npm:     $(npm --version)"
echo

# ------------------------------------------------------------
# 2. Create LM Studio directory
# ------------------------------------------------------------

mkdir -p "$LMSTUDIO_DIR"

# ------------------------------------------------------------
# 3. Backup existing MCP configuration
# ------------------------------------------------------------

if [ -f "$MCP_FILE" ]; then
    cp "$MCP_FILE" "$BACKUP_FILE"
    echo "Backed up existing configuration:"
    echo "  $BACKUP_FILE"
fi

# ------------------------------------------------------------
# 4. Get Brave API key
# ------------------------------------------------------------

if [ -z "${BRAVE_API_KEY:-}" ]; then
    echo
    echo "Brave Search requires an API key."
    echo
    read -r -p "Enter BRAVE_API_KEY (leave blank to configure later): " BRAVE_API_KEY
fi

# ------------------------------------------------------------
# 5. Generate MCP configuration
# ------------------------------------------------------------

python3 - "$MCP_FILE" "$BRAVE_API_KEY" <<'PY'
import json
import os
import sys

mcp_file = sys.argv[1]
brave_key = sys.argv[2]

# Preserve existing configuration if possible.
if os.path.exists(mcp_file):
    try:
        with open(mcp_file, "r") as f:
            config = json.load(f)
    except Exception:
        print(f"WARNING: Existing {mcp_file} is not valid JSON.")
        print("Creating a new configuration.")
        config = {}
else:
    config = {}

if "mcpServers" not in config or not isinstance(config["mcpServers"], dict):
    config["mcpServers"] = {}

servers = config["mcpServers"]

# ------------------------------------------------------------
# Brave Search
# ------------------------------------------------------------

brave = {
    "command": "npx",
    "args": [
        "-y",
        "@brave/brave-search-mcp-server",
        "--transport",
        "stdio"
    ]
}

if brave_key:
    brave["env"] = {
        "BRAVE_API_KEY": brave_key
    }

servers["brave-search"] = brave

# ------------------------------------------------------------
# Weather
# ------------------------------------------------------------

servers["weather"] = {
    "command": "npx",
    "args": [
        "-y",
        "@dangahagan/weather-mcp@latest"
    ]
}

# ------------------------------------------------------------
# Amazon
#
# HasData hosted MCP.
#
# This is intentionally disabled unless AMAZON_MCP_API_KEY
# is supplied.
# ------------------------------------------------------------

amazon_key = os.environ.get("AMAZON_MCP_API_KEY", "")

if amazon_key:
    servers["amazon"] = {
        "url": "https://mcp.hasdata.com/mcp?apis=amazon",
        "headers": {
            "x-api-key": amazon_key
        }
    }
else:
    print("NOTE: Amazon MCP not enabled.")
    print("      Set AMAZON_MCP_API_KEY and rerun the script.")

# ------------------------------------------------------------
# Walmart
#
# HasData hosted MCP.
# ------------------------------------------------------------

walmart_key = os.environ.get("WALMART_MCP_API_KEY", "")

if walmart_key:
    servers["walmart"] = {
        "url": "https://mcp.hasdata.com/mcp?apis=walmart",
        "headers": {
            "x-api-key": walmart_key
        }
    }
else:
    print("NOTE: Walmart MCP not enabled.")
    print("      Set WALMART_MCP_API_KEY and rerun the script.")

# ------------------------------------------------------------
# Home Depot
#
# Local browser-automation MCP.
#
# We add it, but don't install/login automatically because
# authentication may require interactive CAPTCHA/verification.
# ------------------------------------------------------------

servers["homedepot"] = {
    "command": "npx",
    "args": [
        "-y",
        "@striderlabs/mcp-homedepot"
    ]
}

with open(mcp_file, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

print(f"\nWrote {mcp_file}")
PY

# ------------------------------------------------------------
# 6. Display configuration
# ------------------------------------------------------------

echo
echo "============================================================"
echo "LM Studio MCP configuration"
echo "============================================================"
echo

cat "$MCP_FILE"

echo
echo "============================================================"
echo "Done"
echo "============================================================"
echo
echo "MCP configuration:"
echo "  $MCP_FILE"
echo
echo "Restart LM Studio for the changes to take effect."
echo
echo "Installed/configured:"
echo "  - Brave Search"
echo "  - Weather"
echo "  - Home Depot"
echo
echo "Optional:"
echo "  - Amazon"
echo "  - Walmart"
echo
