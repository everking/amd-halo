#!/usr/bin/env bash
# Download Qwen3-Coder-Next into Lemonade, next to the models already on disk.
# The registered recipe is Qwen3-Coder-Next-GGUF (unsloth MXFP4 MoE, about 48 GB).
# This does not load the model, so a model already in memory stays loaded.
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
