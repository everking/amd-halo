#!/usr/bin/env bash
# Authenticate cloudflared with Cloudflare.
# Run this once to obtain an origin certificate.
set -euo pipefail
cloudflared tunnel login
