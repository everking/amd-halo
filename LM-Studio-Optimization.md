# LM Studio optimization (amd-halo / Strix Halo)

Documentation of inference tuning applied on **2026-10-03** for headless LM Studio (`lms` + `llmster` + `llama.cpp`). Follow-up checklist: [`ToDo.md`](ToDo.md).

## Environment

| Item | Detail |
|------|--------|
| CPU | AMD Ryzen AI Max+ 395 — 16 cores / 32 threads, AVX-512 capable |
| GPU | AMD Radeon **8060S** (`gfx1151`), unified memory with system RAM |
| RAM | ~125 GiB |
| LM Studio | **2.41.0** llama.cpp backends (CPU AVX2, Vulkan AVX2, CUDA AVX2 installed; **CUDA unused**, no NVIDIA GPU) |
| Deployment | **Headless only** — no LM Studio desktop/Electron app in use |
| API | `lms server` on **0.0.0.0:1234** |
| Primary model tuned | `qwen/qwen3.6-35b-a3b` (GGUF Q4_K_M + vision `mmproj`) |

### How processes fit together

```text
lms (CLI)  →  llmster  (~/.lmstudio/llmster/…/llmster)
                ↓
            llama-server  (per loaded model; bundled under ~/.lmstudio/extensions/backends/…)
```

- **`lm-studio.service`** (amd-halo) starts `llmster`, the API, and the default model at boot (requires `loginctl enable-linger`; installed by `setup.sh` / `bin/install-lm-studio-service.sh`).
- **`configure-server-power.sh`** (amd-halo) disables idle suspend so the host stays reachable for remote tunnel/API use (`setup.sh` section 11c; see README **Rebuild from scratch**).
- **`cloudflared-llm.service`** tunnels to the API; it **depends on** `lm-studio.service` when installed via `~/bin/cloudflared-llm.sh`.
## Baseline (before optimization)

Observed on **2026-10-03** prior to changes:

| Setting | Before |
|---------|--------|
| Selected GGUF engine | **CPU** `llama.cpp-linux-x86_64-avx2` (preference file + runtime) |
| `llama-server` backend path | `…/llama.cpp-linux-x86_64-avx2-2.41.0/llama-server` |
| GPU offload | **`--n-gpu-layers 0`** (full CPU inference) |
| Context | **131072** (app default + loaded model) |
| Parallel slots | **4** |
| CPU threads | **12** (on a 32-thread CPU) |
| Flash attention | **off** |
| KV cache K/V | **f16** |
| Load mode | **mmap+mlock** |
| Duplicate loads | Old CPU instance could remain alongside new loads (~48 GiB+ for one Qwen load) |
| Vulkan survey | Not used for inference; CPU runtime reported “No GPUs detected” |

Debian `/usr/bin/llama-server` (0.2.0) is **separate** and CPU-only; LM Studio does not use it unless you point an external tool at it explicitly.

## Changes applied

### 1. Default GGUF engine → Vulkan

**Why:** On Strix Halo, **Vulkan offload** to the 8060S is the practical GPU path in LM Studio (no ROCm/HIP backend in the installed extension set). CPU AVX2 builds also do not use Zen 5 AVX-512.

**What changed:**

- File: `~/.lmstudio/.internal/backend-preferences-v1.json`  
  - `llama.cpp-linux-x86_64-avx2` → **`llama.cpp-linux-x86_64-vulkan-avx2`** (version **2.41.0**).
- CLI: `lms runtime select llama.cpp-linux-x86_64-vulkan-avx2@2.41.0`

**Verify:** `lms runtime ls` — Vulkan row marked **✓** for GGUF.

### 2. Default context length → 64k

**Why:** 128k KV cache is expensive in RAM and latency; 64k is a better default unless long context is required.

**What changed:**

- File: `~/.lmstudio/settings.json`  
  - `defaultContextLength.value`: **131072 → 65536**

**Verify:** New loads inherit 64k unless overridden with `-c` / API `context_length`.

### 3. Model reload with GPU and leaner concurrency

**Why:** Apply Vulkan offload and reduce KV duplication from parallel slots.

**Commands used (representative):**

```bash
~/.lmstudio/bin/lms unload qwen/qwen3.6-35b-a3b   # and duplicate instance ids when present
~/.lmstudio/bin/lms load qwen/qwen3.6-35b-a3b --gpu max -c 65536 --parallel 2
```

**REST API** (optional, same intent):

```bash
TOKEN=$(cat ~/.lmstudio/.internal/lms-key-2)
curl -sS -X POST http://127.0.0.1:1234/api/v1/models/load \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3.6-35b-a3b",
    "context_length": 65536,
    "flash_attention": true,
    "offload_kv_cache_to_gpu": true,
    "echo_load_config": true
  }'
```

**Cleanup:** Removed extra loaded instances (e.g. `qwen/qwen3.6-35b-a3b:2`, `:3`) and terminated orphaned **CPU** `llama-server` processes so only one optimized load remained.

### 4. Headless stack restart

**Why:** Ensure a single `llmster` and API listener after backend switch.

**Steps performed:**

```bash
~/.lmstudio/bin/lms server stop
# terminate stray llmster / llama-server if still present
~/.lmstudio/bin/lms server start --bind 0.0.0.0 --port 1234
~/.lmstudio/bin/lms load qwen/qwen3.6-35b-a3b --gpu max -c 65536 --parallel 2
```

### 5. Boot without login (systemd)

**Why:** API and model should return after reboot with no one logged in (headless server).

**Installed by:** `~/dev/amd-halo/setup.sh` or `~/dev/amd-halo/bin/install-lm-studio-service.sh`.

| Piece | Location |
|-------|----------|
| Boot logic | `~/bin/lm-studio-boot.sh` (repo: `bin/lm-studio-boot.sh`) |
| Manual start | `~/bin/lm-studio-start.sh` |
| systemd unit | `~/.config/systemd/user/lm-studio.service` (repo: `config/lm-studio.service`) |
| User linger | `sudo loginctl enable-linger $USER` |

```bash
~/dev/amd-halo/bin/install-lm-studio-service.sh
systemctl --user enable --now lm-studio.service
loginctl show-user $USER | grep Linger
journalctl --user -u lm-studio.service -b
```

`ExecStart` runs the same steps as section 4: `lms daemon up`, `lms server start --bind 0.0.0.0 --port 1234`, then `lms load` if needed. Override model/load via `LMS_MODEL` and `LMS_LOAD_ARGS` in the unit environment.

## Target runtime parameters (after)

These are the effective `llama-server` flags LM Studio passed for the optimized Qwen load:

| Parameter | After | Before (reference) |
|-----------|--------|---------------------|
| Backend binary | `…/vulkan-avx2-2.41.0/llama-server` | `…/avx2-2.41.0/llama-server` |
| `--n-gpu-layers` | **999999** (full offload) | **0** |
| `--ctx-size` | **65536** | **131072** |
| `--parallel` | **2** | **4** |
| `--threads` | **12** (unchanged) | **12** |
| `--flash-attn` | **on** | **off** |
| `--cache-type-k` / `-v` | **f16** | **f16** |
| `--load-mode` | **mmap+mlock** | **mmap+mlock** |
| `--kv-offload` / `--kv-unified` | enabled | enabled |
| Vision | **mmproj** still loaded | same |

**Load time observed:** ~4–5 s for Vulkan reload vs. much longer CPU-only bring-up (order-of-magnitude improvement in wall-clock load, not benchmarked to tok/s here).

**Vulkan survey (after):** `lms runtime survey` with Vulkan selected reports **Radeon 8060S** (RADV GFX1151) with ~**83 GiB** VRAM budget (unified memory).

## Expected effects

- **Higher tokens/sec** and faster prefill vs. CPU-only `n-gpu-layers 0`.
- **Lower RAM pressure:** single instance, smaller KV from 64k context and `parallel 2`.
- **Faster model load** (~seconds).
- **Trade-off:** max context **64k** by default; long threads need `-c 131072` or higher.
- **Still CPU-limited in places:** MoE routing, **12 threads**, AVX2 CPU helper code in the bundle, and **mmproj** for vision-capable GGUF.

## Verification (routine)

```bash
~/.lmstudio/bin/lms server status
~/.lmstudio/bin/lms runtime ls
~/.lmstudio/bin/lms ps
pgrep -af llama-server | grep vulkan-avx2
```

Healthy signals:

- One primary model row in `lms ps` with **CONTEXT 65536**, **PARALLEL 2**.
- Process path contains **`vulkan-avx2`** and **`--n-gpu-layers`** not `0`.
- **`--flash-attn on`** (or `auto`).

## Reverting or adjusting

| Goal | Action |
|------|--------|
| CPU-only again | `lms runtime select llama.cpp-linux-x86_64-avx2@2.41.0` + edit `backend-preferences-v1.json` back to avx2; `lms load … --gpu off` |
| 128k context | `lms load qwen/qwen3.6-35b-a3b --gpu max -c 131072 --parallel 2` and/or set `defaultContextLength.value` to **131072** in `settings.json` |
| More API concurrency | `lms load … --parallel 4` (uses more KV RAM) |
| Standard load one-liner | `lms load qwen/qwen3.6-35b-a3b --gpu max -c 65536 --parallel 2` |

## Not changed (intentionally or blocked)

Documented in [`ToDo.md`](ToDo.md):

- **CPU thread count** (still 12; no `lms load --threads` in current CLI).
- **KV quant** (q8_0 vs f16), **MoE CPU expert** tuning, dropping **mmproj** for text-only.
- **Per-model persisted defaults** in LM Studio’s internal store (usually edited via desktop gear UI).
- **`modelLoadingGuardrails`** in `settings.json` still **high** (4 GiB threshold) — unchanged.
- **Custom llama.cpp** build (AVX-512 / HIP) — not installed.

## Files touched summary

| File | Change |
|------|--------|
| `~/.lmstudio/.internal/backend-preferences-v1.json` | Vulkan backend for GGUF |
| `~/.lmstudio/settings.json` | `defaultContextLength` 65536 |
| `~/dev/amd-halo/config/lm-studio.service` | systemd user unit for boot |
| `~/dev/amd-halo/bin/lm-studio-boot.sh` | Headless start script |
| `~/dev/amd-halo/bin/install-lm-studio-service.sh` | Installs unit + linger + scripts |
| `~/ToDo.md` | Follow-up checklist (headless-oriented) |
| `~/LM-Studio-Optimization.md` | This document |

No model weights or GGUF files were modified.

## Related paths

- Backends: `~/.lmstudio/extensions/backends/llama.cpp-linux-x86_64-*-2.41.0/`
- Logs: `~/.lmstudio/server-logs/`
- CLI: `~/.lmstudio/bin/lms`
- Helper scripts: `~/bin/lm-studio-boot.sh`, `~/bin/lm-studio-start.sh`, `~/dev/amd-halo/bin/install-lm-studio-service.sh`, `~/.local/bin/lm-toggle.sh`
