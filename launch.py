#!/usr/bin/env python3
"""
Patches torch.xpu for unified memory iGPUs before starting ComfyUI.

Intel's Linux driver reports ~50% of system RAM as GPU memory.
This patch makes PyTorch report the full system RAM, so ComfyUI
enters SHARED mode and uses the entire memory pool.

Without this patch:
  Total VRAM 14397 MB, total RAM 31590 MB
  Set vram state to: NORMAL_VRAM   ← treats 14GB as a hard ceiling

With this patch:
  Total VRAM 32614 MB, total RAM 31590 MB
  Set vram state to: NORMAL_VRAM   ← but now 32GB is available
"""
import sys
import os

# Set up ComfyUI paths BEFORE any ComfyUI imports
sys.path.insert(0, '/app/ComfyUI')
os.chdir('/app/ComfyUI')

import torch
import psutil

# ── Patch torch.xpu.get_device_properties ──
_orig_get_props = torch.xpu.get_device_properties

def _patched_get_device_properties(device=None):
    props = _orig_get_props(device)
    # Report full system RAM + 1GB buffer so total_vram > total_ram
    # This ensures ComfyUI sees the full unified memory pool
    full_ram = psutil.virtual_memory().total + (1024 ** 3)
    try:
        props.total_memory = full_ram
    except (AttributeError, TypeError):
        # Properties object might be immutable on some PyTorch versions
        class _PatchedProps:
            pass
        p = _PatchedProps()
        for attr in dir(props):
            if not attr.startswith('_'):
                try:
                    setattr(p, attr, getattr(props, attr))
                except Exception:
                    pass
        p.total_memory = full_ram
        return p
    return props

torch.xpu.get_device_properties = _patched_get_device_properties

# ── Set up argv as if we ran main.py directly ──
sys.argv = ['main.py', '--listen', '0.0.0.0', '--port', '8188']

# ── Launch ComfyUI using importlib (preserves module structure) ──
import importlib.util

spec = importlib.util.spec_from_file_location("__main__", "/app/ComfyUI/main.py")
module = importlib.util.module_from_spec(spec)
sys.modules["__main__"] = module
spec.loader.exec_module(module)