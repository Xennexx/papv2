#!/bin/bash
set -e

current_dir=$(dirname "$(realpath "$0")")
cd $current_dir
source .env

# Set up a trap to call the error_exit function on ERR signal
trap 'error_exit "### ERROR ###"' ERR

echo "### Setting up Stable Diffusion Comfy (Instance 3) ###"
log "Setting up Stable Diffusion Comfy Instance 3"

# Wait for main.sh to complete the installation (creates prepared file)
# Do NOT create venv or touch prepared file - that's main.sh's job
echo "Waiting for main.sh to complete installation..."
WAIT_COUNT=0
MAX_WAIT=120  # Wait up to 10 minutes (120 x 5 seconds)
while [[ ! -f "$VENV_DIR/sd_comfy-env/.prepared" ]]; do
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
        echo "ERROR: Timeout waiting for main.sh to complete installation"
        exit 1
    fi
    if [[ $((WAIT_COUNT % 12)) -eq 0 ]]; then
        echo "Still waiting for main.sh... ($WAIT_COUNT x 5s elapsed)"
    fi
done

echo "main.sh completed, activating venv..."
source $VENV_DIR/sd_comfy-env/bin/activate
log "Finished Preparing Environment for Stable Diffusion Comfy"


if [[ -z "$INSTALL_ONLY" ]]; then
  echo "### Starting Stable Diffusion Comfy ###"
  log "Starting Stable Diffusion Comfy"
  cd "$REPO_DIR"
  # [qwen-box] dedicated Qwen box -> fp8 unet (QwenImage ~38GB bf16 OOMs a 48GB A6000;
  # fp8 keeps it ~28GB resident). Default -> original --highvram for SDXL boxes.
  if [ -f /notebooks/sd_comfy/.qwen_dedicated_box ]; then
    COM3_LAUNCH="python main.py --dont-print-server --fp8_e4m3fn-unet --port 7101 --fast --preview-method none"
  else
    COM3_LAUNCH="python main.py --dont-print-server --highvram --fast --preview-method none --port 7101"
  fi
  PYTHONUNBUFFERED=1 service_loop "$COM3_LAUNCH" > $LOG_DIR/sd_comfy3.log 2>&1 &
  echo $! > /tmp/sd_comfy3.pid
fi

if env | grep -q "PAPERSPACE"; then
  echo "Link: https://$PAPERSPACE_FQDN/com3/"
fi


echo "### Done ###"
