#!/bin/bash
# [krea-lane] PornMaster Krea2 lane (stuffer.ai premium model, 2026-11-23). Started by entry.sh ONLY on an account
# whose /storage/.krea_lane marker exists; that box runs sd-comfy + com2 + this lane (main3.sh, main4.sh, manage.sh,
# auto_restart.js and warmup_common.py skip com3/com4 there). Its own ComfyUI v0.45.6 checkout + venv on /storage
# (installed once by /storage/comfy-next/krea_install.sh); nothing shared with /storage/stable-diffusion-comfy.
# Port 7103, reached through jupyter-server-proxy's /proxy/7103/ route. A non-empty marker file holds the launch
# extra flags (one line, appended), so they can be tuned per account without a repo change. No marker = nothing runs.

current_dir=$(dirname "$(realpath "$0")")
cd $current_dir
source .env

if [ ! -f /storage/.krea_lane ]; then
  echo "[krea] no /storage/.krea_lane marker; not starting"
  exit 0
fi
KREA_DIR=/storage/comfy-next/ComfyUI
KREA_PY=/storage/comfy-next-env/bin/python
if [ ! -x "$KREA_PY" ] || [ ! -f "$KREA_DIR/main.py" ]; then
  echo "[krea] install missing ($KREA_DIR, $KREA_PY); not starting"
  exit 0
fi

# Default flags; the marker's first line (if any) is appended, so it can add or override flags (argparse: last
# value wins) but a blank/odd marker can never drop --listen/--port.
KREA_FLAGS="--listen 127.0.0.1 --port 7103 --disable-pinned-memory --reserve-vram 2 --preview-method none --disable-all-custom-nodes"
KREA_EXTRA="$(head -n 1 /storage/.krea_lane 2>/dev/null | tr -d '\r' | head -c 1000)"
if [ -n "${KREA_EXTRA//[[:space:]]/}" ]; then
  KREA_FLAGS="$KREA_FLAGS $KREA_EXTRA --listen 127.0.0.1 --port 7103"
fi

echo "### Starting Krea lane (port 7103) ###"
cd "$KREA_DIR"
# Own compile caches: entry.sh wipes /storage/.torch_compile_cache whole when it passes 10 GB.
export TORCHINDUCTOR_CACHE_DIR=/storage/.krea_compile_cache/inductor
export TRITON_CACHE_DIR=/storage/.krea_compile_cache/triton
PYTHONUNBUFFERED=1 service_loop "$KREA_PY main.py $KREA_FLAGS" > $LOG_DIR/sd_comfy_krea.log 2>&1 &
echo $! > /tmp/sd_comfy_krea.pid
echo "### Krea lane launched (log $LOG_DIR/sd_comfy_krea.log) ###"
