# ComfyUI Paperspace Troubleshooting Guide

**Last Updated:** 2026-01-24
**Issue Status:** FIXED - Attempt #7

## Environment Overview

- **Platform:** Paperspace Notebook
- **Persistent Storage:** `/storage/` only - everything else wiped on reboot
- **Repo:** https://github.com/Xennexx/papv2 - pulled fresh on each boot
- **Venv Location:** `/tmp/sd_comfy-env` (NOT PERSISTENT - recreated each boot)
- **ComfyUI Location:** `/storage/stable-diffusion-comfy/`

## Issue Summary: torchaudio Version Mismatch

### Root Causes (Multiple!)

**Bug 1: Race Condition in Startup Scripts**
- main2.sh, main3.sh, main4.sh could create empty venv and touch prepared file
- If main.sh failed, these scripts would mark installation as "complete" without packages

**Bug 2: Version Check Timing**
- Version check ran BEFORE all pip installs completed
- `ultralytics` requires `torch<2.10`, which downgrades torch
- Check saw matching versions (2.10.0), then ultralytics downgraded to 2.9.1
- torchaudio stayed at 2.10.0 = MISMATCH

### Fixes Applied

**Fix 1: Race Condition (Commit d775a23)**
- main2.sh, main3.sh, main4.sh now WAIT for main.sh (poll for prepared file)
- Only main.sh can create venv and prepared file
- Added timeout (10 min) with clear error message

**Fix 2: Version Check Timing (Commit 7579a42)**
- Moved version check to AFTER all pip installs
- Use `pip show` instead of Python import (avoids crash on mismatch)
- Added fallback if cu128 index fails

### Current Behavior

1. main.sh installs xformers (torch 2.10.0)
2. main.sh installs requirements.txt (torchaudio 2.10.0)
3. main.sh installs ultralytics (downgrades torch to 2.9.1)
4. Version check detects mismatch: torch=2.9.1, torchaudio=2.10.0
5. Reinstalls torchaudio=2.9.1+cu128 from PyTorch CUDA index
6. Final versions match: torch=2.9.1+cu128, torchaudio=2.9.1+cu128

### How to Verify

```bash
/tmp/sd_comfy-env/bin/python -c "import torch; import torchaudio; print('torch:', torch.__version__); print('torchaudio:', torchaudio.__version__); print('CUDA:', torch.cuda.is_available())"
```

Expected output:
```
torch: 2.9.1+cu128
torchaudio: 2.9.1+cu128
CUDA: True
```

### Files Modified

| File | Change |
|------|--------|
| `sd_comfy/main.sh` | Version check moved to after all pip installs |
| `sd_comfy/main2.sh` | Replaced venv creation with wait loop |
| `sd_comfy/main3.sh` | Replaced venv creation with wait loop |
| `sd_comfy/main4.sh` | Replaced venv creation with wait loop |
| `sd_comfy/manage.sh` | Same version check fix as main.sh |

### Architecture Notes

- **entry.sh** - Runs on boot, calls main.sh through main4.sh sequentially
- **main.sh** - Does ALL package installation, creates `/tmp/sd_comfy.prepared`, starts instance 1
- **main2.sh, main3.sh, main4.sh** - Wait for prepared file, then start instances 2, 3, 4
- All instances share the SAME venv at `/tmp/sd_comfy-env`
- **manage.sh** - Utility script for manual start/stop/restart/status

### Instance Configuration

| Instance | Port | URL Path | Log File |
|----------|------|----------|----------|
| 1 | 7005 | /sd-comfy/ | /tmp/log/sd_comfy.log |
| 2 | 7100 | /com2/ | /tmp/log/sd_comfy2.log |
| 3 | 7101 | /com3/ | /tmp/log/sd_comfy3.log |
| 4 | 7102 | /com4/ | /tmp/log/sd_comfy4.log |

### Manual Fix (if needed)

```bash
# Stop all instances
bash /notebooks/sd_comfy/manage.sh stop all

# Get current torch version
TORCH_VER=$(/tmp/sd_comfy-env/bin/python -c "import torch; print(torch.__version__)")

# Reinstall torchaudio to match
/tmp/sd_comfy-env/bin/pip install --force-reinstall --no-deps \
    torchaudio==${TORCH_VER} \
    --index-url https://download.pytorch.org/whl/cu128

# Restart instances
bash /notebooks/sd_comfy/manage.sh start all
```

### Previous Fix Attempts

| Attempt | Date | Issue |
|---------|------|-------|
| 1-4 | Unknown | Details lost |
| 5 | 2026-01-24 | Fixed main.sh torchaudio logic, but race condition caused empty venv |
| 6 | 2026-01-24 | Fixed race condition, but version check ran too early |
| 7 | 2026-01-24 | **FIXED** - Moved version check to after all pip installs |

---

## Session Handoff Notes

When starting a new session:
1. Read this file first
2. Check if instances are running: `bash /notebooks/sd_comfy/manage.sh status all`
3. Check torch/torchaudio versions match (see verify command above)
4. If mismatch, use manual fix above
5. Update this document with findings and push to GitHub
