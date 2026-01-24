#!/bin/bash
set -e

current_dir=$(dirname "$(realpath "$0")")
cd $current_dir
source .env

# Set up a trap to call the error_exit function on ERR signal
trap 'error_exit "### ERROR ###"' ERR

echo "### Setting up Stable Diffusion Comfy (Instance 4) ###"
log "Setting up Stable Diffusion Comfy Instance 4"

# Wait for main.sh to complete the installation (creates prepared file)
# Do NOT create venv or touch prepared file - that's main.sh's job
echo "Waiting for main.sh to complete installation..."
WAIT_COUNT=0
MAX_WAIT=120  # Wait up to 10 minutes (120 x 5 seconds)
while [[ ! -f "/tmp/sd_comfy.prepared" ]]; do
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
  PYTHONUNBUFFERED=1 service_loop "python main.py --dont-print-server --highvram --port 7102" > $LOG_DIR/sd_comfy4.log 2>&1 &
  echo $! > /tmp/sd_comfy.pid
fi

if env | grep -q "PAPERSPACE"; then
  echo "Link: https://$PAPERSPACE_FQDN/com4/"
fi


echo "### Done ###"
