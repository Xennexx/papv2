# ComfyUI Paperspace Troubleshooting Guide

**Last Updated:** 2026-01-24
**Issue Status:** INVESTIGATING - Fix attempt #5

## Environment Overview

- **Platform:** Paperspace Notebook
- **Persistent Storage:** `/storage/` only - everything else wiped on reboot
- **Repo:** https://github.com/Xennexx/papv2 - pulled fresh on each boot
- **Venv Location:** `/tmp/sd_comfy-env` (NOT PERSISTENT - recreated each boot)
- **ComfyUI Location:** `/storage/stable-diffusion-comfy/`

## Current Issue: torchaudio Version Mismatch

### Symptoms
- ComfyUI instances keep rebooting/crashing
- Error related to torchaudio version incompatibility
- PyTorch version: 2.9.1+cu128
- torchaudio gets installed as: 2.10.0 (WRONG - should be 2.9.1+cu128)

### Root Cause Analysis

1. **requirements.txt** in ComfyUI (`/storage/stable-diffusion-comfy/requirements.txt`) contains bare `torchaudio` without version pin
2. When `pip install -r requirements.txt` runs, it installs LATEST torchaudio (2.10.0) from PyPI
3. Previous fix attempts tried to install correct version BEFORE requirements.txt - got overwritten
4. The CUDA index URL requires the FULL version string with suffix (e.g., `2.9.1+cu128`, not `2.9.1`)

### Previous Fix Attempts

#### Attempt 1-3: Unknown (before documentation)
- Modified entry.sh and main.sh
- Details lost due to session resets

#### Attempt 4: (2026-01-24)
- Modified main.sh to get torch version and install matching torchaudio
- **Problem:** Used `cut -d'+' -f1` which removed the `+cu128` suffix
- **Problem:** Installed torchaudio BEFORE requirements.txt, which then overwrote it
- **Result:** Failed - torchaudio still mismatched after reboot

#### Attempt 5: (2026-01-24) - CURRENT
- **Fix Applied:** Modified main.sh to:
  1. Install requirements.txt FIRST
  2. Get FULL torch version WITH cuda suffix
  3. Force reinstall torchaudio AFTER requirements.txt
  4. Added verification output to confirm versions match

### Files Modified

#### `/notebooks/sd_comfy/main.sh`
Key changes:
```bash
# Install requirements FIRST (this will install torch, torchvision, torchaudio)
pip install -r requirements.txt

# NOW get the installed torch version WITH the cuda suffix (e.g., 2.9.1+cu128)
TORCH_VERSION_FULL=$(pip show torch | grep "^Version:" | cut -d' ' -f2)

# Force reinstall torchaudio and torchvision from PyTorch CUDA index
pip install --force-reinstall --no-deps \
    torchaudio==${TORCH_VERSION_FULL} \
    torchvision==${TORCH_VERSION_FULL} \
    --index-url https://download.pytorch.org/whl/cu128
```

### How to Verify Fix Worked

After reboot, run:
```bash
/tmp/sd_comfy-env/bin/python -c "import torch; import torchaudio; print('torch:', torch.__version__); print('torchaudio:', torchaudio.__version__)"
```

Expected output (versions should match):
```
torch: 2.9.1+cu128
torchaudio: 2.9.1+cu128
```

### Manual Fix (if automatic fix fails)

```bash
# Stop all instances
cd /notebooks/sd_comfy && bash manage.sh stop all

# Fix torchaudio
/tmp/sd_comfy-env/bin/pip install --force-reinstall --no-deps \
    torchaudio==2.9.1+cu128 \
    --index-url https://download.pytorch.org/whl/cu128

# Restart instances
bash manage.sh start all
```

### Architecture Notes

- **main.sh** - Does ALL package installation, creates `/tmp/sd_comfy.prepared`
- **main2.sh, main3.sh, main4.sh** - Skip install if prepared file exists, just start instances
- All instances share the SAME venv at `/tmp/sd_comfy-env`
- **manage.sh** - Control script for start/stop/restart/status of instances

### Instance Configuration

| Instance | Port | URL Path | Log File |
|----------|------|----------|----------|
| 1 | 7005 | /sd-comfy/ | /tmp/log/sd_comfy.log |
| 2 | 7100 | /com2/ | /tmp/log/sd_comfy2.log |
| 3 | 7101 | /com3/ | /tmp/log/sd_comfy3.log |
| 4 | 7102 | /com4/ | /tmp/log/sd_comfy4.log |

### Next Steps If Issue Persists

1. Check if `/tmp/sd_comfy.prepared` is being created too early (before fix runs)
2. Consider moving venv to `/storage/` for persistence (would require .env changes)
3. Check if ComfyUI-Manager is reinstalling packages on first launch
4. Check custom nodes for their own pip installs
5. Consider patching ComfyUI's requirements.txt to pin torchaudio version

### Pushing Changes

The GitHub token is provided by the user in the conversation. Push changes with:

```bash
cd /notebooks
git add -A
git commit -m "Fix description here"
git push origin master
```

---

## Session Handoff Notes

When starting a new session:
1. Read this file first
2. Check current torch/torchaudio versions
3. Check if instances are running with `bash /notebooks/sd_comfy/manage.sh status all`
4. If issue persists, try next fix from "Next Steps" section
5. Update this document with findings and push to GitHub
