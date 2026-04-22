# ComfyUI Intel Arc GPU Container

Run [ComfyUI](https://github.com/comfyanonymous/ComfyUI) with full Intel Arc GPU acceleration inside Docker — including a **VRAM detection patch** that unlocks your entire memory pool on iGPU systems.

## The Problem This Solves

Intel's Linux graphics driver reports only ~50% of system RAM as available GPU memory. On a 32GB system, ComfyUI sees just 14GB of "VRAM" and OOMs at that ceiling — even though your iGPU can access all 32GB.

This repository includes a `launch.py` patch that fixes the detection, so ComfyUI can use the full unified memory pool.

| | Without Patch | With Patch |
|---|---|---|
| **VRAM Reported** | 14,397 MB | 32,614 MB |
| **Memory Mode** | NORMAL_VRAM (capped) | NORMAL_VRAM (full pool) |
| **Max Model Size** | ~12 GB | ~28 GB |
| **Can Run FLUX FP8?** | ❌ OOM | ✅ Works |

## Quick Start

```bash
# Clone the repository
git clone https://github.com/procrastinando/comfyui-intel-arc-gpu-container.git
cd comfyui-intel-arc-gpu-container

# Create persistent directories for models and outputs
mkdir -p comfy/{output,models,input,custom_nodes,user,cache}

# Build and start
docker compose up -d

# Watch the logs
docker compose logs -f
```

Then open [http://localhost:8188](http://localhost:8188) in your browser.

**You should see in the logs:**
```
Total VRAM 32614 MB, total RAM 31590 MB
pytorch version: 2.11.0+xpu
Set vram state to: NORMAL_VRAM
Device: xpu:0 Intel(R) Arc(TM) Graphics
```

If `Total VRAM` shows ~14GB instead of your full RAM, the patch isn't loading — check that `launch.py` is mounted correctly.

## Prerequisites

| Requirement | Details |
|---|---|
| **Hardware** | Intel Core Ultra (Meteor Lake / Arrow Lake / Lunar Lake) with Arc iGPU, or Intel Arc discrete GPU |
| **OS** | Linux with Docker support |
| **Docker** | Docker CE 24+ and Docker Compose v2 |
| **RAM** | 16 GB minimum, 32 GB+ recommended |
| **Kernel** | 6.1+ recommended for Intel Arc support |

Verify your iGPU is visible:

```bash
ls /dev/dri/
# Should show: card0  renderD128  (or similar)
```

## Files Explained

### Dockerfile

Builds a ComfyUI image with:

- Intel Level Zero runtime and OpenCL ICD for Arc GPU compute
- Intel media drivers for hardware-accelerated video encoding
- PyTorch with XPU support (from `torch` nightly)
- All ComfyUI Python dependencies

### launch.py

Patches `torch.xpu.get_device_properties` to report full system RAM instead of the ~50% cap set by Intel's driver, then launches ComfyUI. Without this, ComfyUI treats your unified memory iGPU as a discrete GPU with limited VRAM and OOMs at ~14GB.

### docker-compose.yml

Configures the container with:

- **`devices: /dev/dri`** — passes the Intel GPU through to the container
- **`shm_size: 8gb`** — prevents DataLoader bus errors (Docker default is only 64MB)
- **Volume mounts** — persists models, outputs, and shader cache across restarts
- **Environment variables** — tunes Intel's Level Zero runtime and shader compiler

## Environment Variables

| Variable | What It Does | Why It Matters |
|---|---|---|
| `ZE_INTEL_FORCE_SHARED_MEM=1` | Forces shared memory allocations for the iGPU | **Critical** — enables the GPU to access all system RAM, not just the VRAM partition |
| `ZE_AFFINITY_MASK=0` | Pins execution to GPU device 0 | Prevents device selection errors on multi-GPU systems |
| `ONEAPI_DEVICE_SELECTOR=level_zero:0` | Selects Level Zero compute device 0 | Avoids falling back to CPU or wrong compute device |
| `IGC_EnableParallelCompilation=1` | Compiles GPU kernels in parallel | **Dramatic speedup** on first run — shader compilation drops from minutes to seconds |
| `IGC_WorkerThreadCount=14` | Number of parallel compiler threads | Adjust to your CPU core count minus 2 |
| `IGC_ShaderCacheSizeInMB=102400` | Max shader cache size (100 GB) | Prevents cache eviction and recompilation on restart |
| `PIP_BREAK_SYSTEM_PACKAGES=1` | Allows global pip installs | Required for GitPython install on Ubuntu 24.04+ |

## Troubleshooting

### "Total VRAM" shows ~14GB instead of ~32GB

The `launch.py` patch isn't being loaded. Check that:

1. `launch.py` exists in the same directory as `docker-compose.yml`
2. The volume mount `./launch.py:/app/launch.py:ro` is present in `docker-compose.yml`
3. The container command runs `python3 /app/launch.py` — not `python3 main.py` directly

### "comfy-aimdo failed to load: libcuda.so.1"

**This is harmless.** ComfyUI's dynamic memory allocator (AIMDO) is NVIDIA-only. Your system uses the legacy memory manager, which works correctly with the VRAM patch applied.

### Container starts but GPU isn't detected

```bash
docker compose exec comfyui clinfo
# Should list your Intel GPU
```

If empty, verify `/dev/dri/` exists on the host and the `devices:` mount is in `docker-compose.yml`.

### First run is very slow

The first generation requires compiling GPU kernels (2–5 minutes). Subsequent runs are fast. The `IGC_*` environment variables and persisted `cache/` volume ensure you only pay this cost once.

### DataLoader bus errors

Make sure `shm_size: 8gb` (or higher) is set in `docker-compose.yml`. Docker's default 64MB is insufficient for AI workloads.

### "XPU out of memory" errors

You're loading a model larger than your available RAM. Use FP8 quantized checkpoints or close other applications to free memory.

## Rebuilding

After updating the Dockerfile or upgrading ComfyUI:

```bash
# Pull the latest image and rebuild
docker compose down
docker compose build --no-cache
docker compose up -d
```

To update ComfyUI to the latest version:

```bash
docker compose down
docker compose build --no-cache
docker compose up -d
```

The `comfy/models`, `comfy/output`, and `comfy/cache` directories persist on your host and won't be lost during rebuilds.

## How the VRAM Patch Works

```
┌─────────────────────────────────────────────────┐
│          Without launch.py                      │
│                                                 │
│  Intel Driver  →  PyTorch  →  ComfyUI           │
│  "14.4 GB VRAM"    14.4 GB      NORMAL_VRAM     │
│                                  (14GB ceiling) │
│                                  OOM at ~14 GB  │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│          With launch.py                         │
│                                                 │
│  psutil  →  Patched PyTorch  →  ComfyUI         │
│  "32.6 GB"     32.6 GB          NORMAL_VRAM     │
│                                 (full pool)     │
│                                 Uses all 32 GB  │
└─────────────────────────────────────────────────┘
```

The patch intercepts `torch.xpu.get_device_properties()` and replaces the `total_memory` value with the full system RAM (plus a 1GB buffer). This tells ComfyUI it has access to the entire unified memory pool, which is the reality on iGPU systems.

## Hardware Compatibility

Tested on:

- Intel Core Ultra Series 2 (Arrow Lake) with Arc 130T iGPU
- Debian 13

Should also work on:

- Intel Arc discrete GPUs (A770, A750, B580, etc.)
- Other Linux distributions with Docker support