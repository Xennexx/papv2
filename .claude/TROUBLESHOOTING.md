# ComfyUI Paperspace Troubleshooting Guide

**Last Updated:** 2026-01-24
**Issue Status:** FIXED - torchaudio mismatch (Attempt #7) + entry.sh cleanup (Attempt #8)

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

## Boot Time Optimization (Attempt #8)

### Problem
`entry.sh` had duplicate operations causing ~1.5-2.5 minutes of wasted time on each boot:
- Node.js installed TWICE
- PM2 installed TWICE
- `apt-get update` ran TWICE
- System python packages installed (unnecessary - venv has them)

### Fix Applied (2026-01-24)

Removed duplicate operations from `/notebooks/entry.sh`:

| Lines Removed | Content | Reason |
|---------------|---------|--------|
| 54 | `apt-get update` | Duplicate of line 43 |
| 58-61 | System pip installs (einops, torchsde, spandrel, kornia) | Already in venv via main.sh |
| 88-92 | Node.js installation (second time) | Duplicate of lines 64-68 |
| 94-96 | System pip install (opencv-python, etc.) | Already in venv via main.sh |
| 103-105 | PM2 installation (second time) | Duplicate of lines 70-72 |

**Result:** File reduced from 174 lines to 155 lines

### Verification Performed

Simulated fresh boot by:
1. Killed PM2 processes
2. Uninstalled PM2 (`npm uninstall -g pm2`)
3. Removed Node.js (`apt-get remove -y nodejs`)
4. Ran `entry.sh`

**Results:**
- ✅ Node.js: v20.20.0
- ✅ PM2: v6.0.14
- ✅ PM2 Services: 3 processes online (auto-restart, image-cleanup, logrotate)
- ✅ ComfyUI Instance 1: RUNNING (port 7005)
- ✅ ComfyUI Instance 2: RUNNING (port 7100)
- ✅ torch: 2.9.1+cu128
- ✅ torchaudio: 2.9.1+cu128 (MATCHING!)
- ✅ CUDA: Available

### Files Modified

| File | Change |
|------|--------|
| `entry.sh` | Removed duplicate apt-get update, Node.js install, PM2 install, system pip installs |

---

## Session Handoff Notes

### Quick Start for New Claude Session

**If user says "it's still not working after reboot":**

1. **Read this file first** - it has all context
2. **Check current state:**
   ```bash
   # Check instances
   bash /notebooks/sd_comfy/manage.sh status all

   # Check torch versions
   /tmp/sd_comfy-env/bin/python -c "import torch; import torchaudio; print('torch:', torch.__version__); print('torchaudio:', torchaudio.__version__)"

   # Check PM2 services
   pm2 list

   # Check boot logs
   tail -100 /tmp/entry_boot.log
   tail -50 /tmp/log/sd_comfy.log
   ```

3. **Common issues to check:**
   - torchaudio version mismatch → Use manual fix in "Manual Fix" section above
   - PM2 not running → `pm2 status` then check `/tmp/pm2_startup.log`
   - ComfyUI not starting → Check individual log files in `/tmp/log/`
   - Venv missing/empty → Check if `/tmp/sd_comfy.prepared` exists and has content

4. **Key files to examine:**
   - `/notebooks/entry.sh` - Main boot script
   - `/notebooks/sd_comfy/main.sh` - Package installation + Instance 1
   - `/notebooks/sd_comfy/main2.sh`, `main3.sh`, `main4.sh` - Instances 2-4
   - `/notebooks/sd_comfy/manage.sh` - Manual control utility

### What Was Done So Far

| Attempt | Fix | Status |
|---------|-----|--------|
| 1-4 | Various torchaudio fixes | Failed |
| 5 | Fixed main.sh torchaudio logic | Race condition caused empty venv |
| 6 | Fixed race condition (main2-4 wait for main.sh) | Version check ran too early |
| 7 | Moved version check to after ALL pip installs | **FIXED** |
| 8 | Cleaned up entry.sh duplicates (Node.js, PM2, pip) | **OPTIMIZED** - saves ~1.5-2.5 min |

### GitHub Setup (if needed)

The repo uses SSH key authentication:
```bash
# Check if key exists
ls -la ~/.ssh/id_*

# Test GitHub connection
ssh -T git@github.com

# If key missing, generate new one:
ssh-keygen -t ed25519 -C "your_email@example.com"
cat ~/.ssh/id_ed25519.pub
# Add to GitHub: Settings → SSH Keys
```

### To Push Changes to GitHub

```bash
cd /notebooks
git add -A
git commit -m "Description of changes

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
git push origin master
```

### Architecture Diagram

```
entry.sh (boot)
    ├── apt-get update + install deps
    ├── Install Node.js 20.x
    ├── Install PM2
    ├── main.sh → Creates venv, installs ALL packages, starts Instance 1
    │       └── Touches /tmp/sd_comfy.prepared when done
    ├── main2.sh → Waits for prepared file, starts Instance 2
    ├── main3.sh → Waits for prepared file, starts Instance 3
    ├── main4.sh → Waits for prepared file, starts Instance 4
    └── start_pm2_services.sh → Starts auto-restart + image-cleanup
```

### Persistent vs Non-Persistent

| Location | Persistent? | Contents |
|----------|-------------|----------|
| `/storage/` | ✅ YES | Models, ComfyUI repo, outputs |
| `/notebooks/` | ❌ NO | Pulled from GitHub on each boot |
| `/tmp/` | ❌ NO | Venv, logs, PID files |

**Important:** All code changes must be pushed to GitHub or they will be lost on reboot!
