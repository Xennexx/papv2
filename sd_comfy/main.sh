#!/bin/bash
set -e

current_dir=$(dirname "$(realpath "$0")")
cd $current_dir
source .env

# Set up a trap to call the error_exit function on ERR signal
trap 'error_exit "### ERROR ###"' ERR


echo "### Setting up Stable Diffusion Comfy ###"
log "Setting up Stable Diffusion Comfy"
if [[ "$REINSTALL_SD_COMFY" || ! -f "/tmp/sd_comfy.prepared" ]]; then

    
    TARGET_REPO_URL="https://github.com/comfyanonymous/ComfyUI.git" \
    TARGET_REPO_DIR=$REPO_DIR \
    UPDATE_REPO=$SD_COMFY_UPDATE_REPO \
    UPDATE_REPO_COMMIT=$SD_COMFY_UPDATE_REPO_COMMIT \
    prepare_repo 

    symlinks=(
      "$REPO_DIR/output:$IMAGE_OUTPUTS_DIR/stable-diffusion-comfy"
      "$REPO_DIR/temp:$IMAGE_OUTPUTS_DIR/stable-diffusion-comfy/temp"

    )
    prepare_link "${symlinks[@]}"
    rm -rf $VENV_DIR/sd_comfy-env
    
    
    python3.10 -m venv $VENV_DIR/sd_comfy-env
    
    source $VENV_DIR/sd_comfy-env/bin/activate

    pip install --upgrade pip
    pip install --upgrade wheel setuptools
    
    cd $REPO_DIR
    pip install xformers

    # Install requirements FIRST (this will install torch, torchvision, torchaudio)
    pip install -r requirements.txt

    # NOW get the installed torch version WITH the cuda suffix (e.g., 2.9.1+cu128)
    TORCH_VERSION_FULL=$(pip show torch | grep "^Version:" | cut -d' ' -f2)
    echo "Detected torch version: $TORCH_VERSION_FULL"

    # Force reinstall torchaudio and torchvision from PyTorch CUDA index to match torch version
    # This MUST happen AFTER requirements.txt to override any mismatched versions
    pip install --force-reinstall --no-deps \
        torchaudio==${TORCH_VERSION_FULL} \
        torchvision==${TORCH_VERSION_FULL} \
        --index-url https://download.pytorch.org/whl/cu128

    # Verify the versions match
    echo "=== Verifying PyTorch package versions ==="
    pip show torch | grep "^Version:"
    pip show torchaudio | grep "^Version:"
    pip show torchvision | grep "^Version:"

    # Install additional dependencies that custom nodes require
    pip install opencv-python scikit-image piexif segment-anything
    # Install ComfyUI Manager and other custom node dependencies
    pip install GitPython toml rich uv matplotlib ultralytics lpips simpleeval

    
    touch /tmp/sd_comfy.prepared
else
    
    source $VENV_DIR/sd_comfy-env/bin/activate
    
fi
log "Finished Preparing Environment for Stable Diffusion Comfy"






if [[ -z "$INSTALL_ONLY" ]]; then
  echo "### Starting Stable Diffusion Comfy ###"
  log "Starting Stable Diffusion Comfy"
  
  
  cd "$REPO_DIR"
  PYTHONUNBUFFERED=1 service_loop "python main.py --dont-print-server --highvram --port 7005" > $LOG_DIR/sd_comfy.log 2>&1 &
  echo $! > /tmp/sd_comfy.pid
fi

if env | grep -q "PAPERSPACE"; then
  echo "Link: https://$PAPERSPACE_FQDN/sd-comfy/"
fi


echo "### Done ###"

if env | grep -q "PAPERSPACE"; then
  echo "Link: https://$PAPERSPACE_FQDN/sd-comfy/"
fi


echo "### Done ###"
