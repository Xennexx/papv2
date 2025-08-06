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
      "$MODEL_DIR:$WORKING_DIR/models"
      "$MODEL_DIR/sd:$LINK_MODEL_TO"
      "$MODEL_DIR/lora:$LINK_LORA_TO"
      "$MODEL_DIR/vae:$LINK_VAE_TO"
      "$MODEL_DIR/upscaler:$LINK_UPSCALER_TO"
      "$MODEL_DIR/controlnet:$LINK_CONTROLNET_TO"
      "$MODEL_DIR/embedding:$LINK_EMBEDDING_TO"
    )
    prepare_link "${symlinks[@]}"
    rm -rf $VENV_DIR/sd_comfy-env
    
    
    python3.10 -m venv $VENV_DIR/sd_comfy-env
    
    source $VENV_DIR/sd_comfy-env/bin/activate

    pip install --upgrade pip
    pip install --upgrade wheel setuptools
    
    cd $REPO_DIR
    pip install xformers
    pip install torchvision torchaudio --no-deps
    pip install -r requirements.txt
    
    touch /tmp/sd_comfy.prepared
else
    
    source $VENV_DIR/sd_comfy-env/bin/activate
    
fi
log "Finished Preparing Environment for Stable Diffusion Comfy"



if [[ -z "$INSTALL_ONLY" ]]; then
  echo "### Starting Stable Diffusion Comfy ###"
  log "Starting Stable Diffusion Comfy"
  cd "$REPO_DIR"
  PYTHONUNBUFFERED=1 service_loop "python main.py --dont-print-server --highvram --port 7103" > $LOG_DIR/sd_comfy.log 2>&1 &
  echo $! > /tmp/sd_comfy.pid
fi

if env | grep -q "PAPERSPACE"; then
  echo "Link: https://$PAPERSPACE_FQDN/com4/"
fi


echo "### Done ###"
