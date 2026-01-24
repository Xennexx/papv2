# ComfyUI Paperspace Troubleshooting Guide

**Last Updated:** 2026-01-24
**Issue Status:** FIX ATTEMPT #6 - Race condition in startup scripts

## Environment Overview

- **Platform:** Paperspace Notebook
- **Persistent Storage:** `/storage/` only - everything else wiped on reboot
- **Repo:** https://github.com/Xennexx/papv2 - pulled fresh on each boot
- **Venv Location:** `/tmp/sd_comfy-env` (NOT PERSISTENT - recreated each boot)
- **ComfyUI Location:** `/storage/stable-diffusion-comfy/`

## Current Issue: Empty Venv + torchaudio Version Mismatch

### Symptoms (Attempt 6 Investigation)
- ComfyUI instances crash-looping with `ModuleNotFoundError: No module named 'yaml'`
- Venv exists but contains NO packages (only base pip and setuptools)
- `/tmp/sd_comfy.prepared` file exists (indicating "installation complete")
- Torch not installed at all

### Root Cause (FOUND!)

**TWO BUGS WORKING TOGETHER:**

1. **Race Condition Bug:** main2.sh, main3.sh, main4.sh could each create an EMPTY venv and touch the prepared file WITHOUT installing any packages

2. **Flow Breakdown:**
   - entry.sh runs scripts sequentially: main.sh -> main2.sh -> main3.sh -> main4.sh
   - If main.sh FAILS during pip install (due to xformers build or network issues)
   - entry.sh continues (no `set -e`) and runs main2.sh
   - main2.sh sees no prepared file, creates empty venv, touches prepared file
   - main3.sh and main4.sh see prepared file exists, skip install
   - Result: Empty venv with prepared file = broken state

3. **Original Bug:** main2.sh/main3.sh/main4.sh had FULL venv creation blocks that could wipe and recreate the venv:
   ```bash
   # OLD BROKEN CODE in main2.sh, main3.sh, main4.sh:
   if [[ "$REINSTALL_SD_COMFY" || ! -f "/tmp/sd_comfy.prepared" ]]; then
       rm -rf $VENV_DIR/sd_comfy-env
       python3.10 -m venv $VENV_DIR/sd_comfy-env
       touch /tmp/sd_comfy.prepared  # NO PACKAGES INSTALLED!
   fi
   ```

### Fix Applied (Attempt 6)

**Modified main2.sh, main3.sh, main4.sh to:**
1. REMOVE the venv creation/prepared file touch logic
2. Instead, WAIT for main.sh to complete (poll for prepared file)
3. Only main.sh can create the venv and prepared file

**New code pattern:**
```bash
# Wait for main.sh to complete the installation (creates prepared file)
# Do NOT create venv or touch prepared file - that's main.sh's job
WAIT_COUNT=0
MAX_WAIT=120  # Wait up to 10 minutes (120 x 5 seconds)
while [[ ! -f "/tmp/sd_comfy.prepared" ]]; do
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
        echo "ERROR: Timeout waiting for main.sh to complete installation"
        exit 1
    fi
done
source $VENV_DIR/sd_comfy-env/bin/activate
```

**Also fixed:**
- Distinct log files: sd_comfy2.log, sd_comfy3.log, sd_comfy4.log (were all writing to sd_comfy.log)
- Updated manage.sh with proper torchaudio fix

### Files Modified

| File | Change |
|------|--------|
| `/notebooks/sd_comfy/main2.sh` | Replaced venv creation with wait loop |
| `/notebooks/sd_comfy/main3.sh` | Replaced venv creation with wait loop |
| `/notebooks/sd_comfy/main4.sh` | Replaced venv creation with wait loop |
| `/notebooks/sd_comfy/manage.sh` | Added torchaudio version fix |

### Previous Fix Attempts

#### Attempt 1-4: (before documentation)
- Various edits to entry.sh and main.sh
- Details lost due to session resets

#### Attempt 5: (2026-01-24)
- Fixed main.sh to install requirements.txt FIRST, then force reinstall torchaudio AFTER
- **This fix was correct** but couldn't work because main.sh was failing and main2.sh was creating empty venv

#### Attempt 6: (2026-01-24) - CURRENT
- Found the actual root cause: race condition in startup scripts
- Fixed main2.sh, main3.sh, main4.sh to wait for main.sh instead of creating their own venv

### How to Verify Fix Worked

After reboot, run:
```bash
# Check if packages are installed
/tmp/sd_comfy-env/bin/pip list | grep -E "^(torch|torchaudio|torchvision)"

# Check versions match
/tmp/sd_comfy-env/bin/python -c "import torch; import torchaudio; print('torch:', torch.__version__); print('torchaudio:', torchaudio.__version__)"
```

Expected output:
```
torch: 2.9.1+cu128
torchaudio: 2.9.1+cu128
```

### Manual Testing (Without Reboot)

```bash
# Reset state
rm -f /tmp/sd_comfy.prepared
rm -rf /tmp/sd_comfy-env

# Run entry.sh (or just main.sh for faster test)
cd /notebooks && bash entry.sh

# Then verify
/tmp/sd_comfy-env/bin/python -c "import torch; import torchaudio; print('torch:', torch.__version__); print('torchaudio:', torchaudio.__version__)"
```

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

### Next Steps If Issue Persists

1. Check if main.sh itself is failing - look at logs or run manually
2. Consider moving venv to `/storage/` for persistence (edit .env VENV_DIR)
3. Check if xformers installation is causing the main.sh failure
4. Consider adding `|| true` after non-critical pip installs to prevent cascade failures

### Pushing Changes

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
4. If issue persists, check what's in the venv: `/tmp/sd_comfy-env/bin/pip list`
5. Update this document with findings and push to GitHub
