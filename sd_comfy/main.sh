#!/bin/bash
set -e

current_dir=$(dirname "$(realpath "$0")")
cd $current_dir
source .env

# Set up a trap to call the error_exit function on ERR signal
trap 'error_exit "### ERROR ###"' ERR


echo "### Setting up Stable Diffusion Comfy ###"
log "Setting up Stable Diffusion Comfy"

# Force reinstall if torch has wrong CUDA version for this driver
if [[ -f "/tmp/sd_comfy.prepared" ]] && [[ -f "$VENV_DIR/sd_comfy-env/bin/activate" ]]; then
    source $VENV_DIR/sd_comfy-env/bin/activate
    TORCH_CUDA=$( python -c "import torch; print(torch.version.cuda or '')" 2>/dev/null || echo "")
    deactivate 2>/dev/null || true
    if [[ "$TORCH_CUDA" != 12.4* ]]; then
        echo "WARNING: Installed torch uses CUDA $TORCH_CUDA but driver supports 12.4 — forcing reinstall"
        rm -f /tmp/sd_comfy.prepared
    fi
fi

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
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
    pip install xformers --index-url https://download.pytorch.org/whl/cu124

    # Install requirements.txt — use cu124 as primary index so pip doesn't pull cu130 from PyPI
    pip install -r requirements.txt --index-url https://download.pytorch.org/whl/cu124 --extra-index-url https://pypi.org/simple
    # Install additional dependencies that custom nodes require
    pip install opencv-python scikit-image piexif segment-anything
    # Install ComfyUI Manager and other custom node dependencies
    pip install GitPython toml rich uv matplotlib ultralytics lpips

    # Install additional dependencies that custom nodes require
    pip install opencv-python scikit-image piexif segment-anything
    # Install ComfyUI Manager and other custom node dependencies
    # NOTE: ultralytics requires torch<2.10 which can downgrade torch and cause mismatch!
    pip install GitPython toml rich uv matplotlib ultralytics lpips simpleeval

    # === VERSION CHECK AND FIX ===
    # Must happen AFTER all pip installs, as some packages (like ultralytics) can downgrade torch
    echo "=== Checking PyTorch/torchaudio version compatibility ==="
    TORCH_VERSION=$(python -c "import torch; print(torch.__version__)")
    # torchaudio may fail to import if there's a mismatch, so use pip show instead
    TORCHAUDIO_VERSION=$(pip show torchaudio | grep "^Version:" | cut -d' ' -f2)
    echo "Detected torch version: $TORCH_VERSION"
    echo "Detected torchaudio version: $TORCHAUDIO_VERSION"

    # Extract base version (e.g., "2.9.1" from "2.9.1+cu128" or "2.10.0")
    TORCH_BASE=$(echo "$TORCH_VERSION" | cut -d'+' -f1)
    TORCHAUDIO_BASE=$(echo "$TORCHAUDIO_VERSION" | cut -d'+' -f1)

    if [[ "$TORCH_BASE" != "$TORCHAUDIO_BASE" ]]; then
        echo "WARNING: Version mismatch detected! torch=$TORCH_VERSION, torchaudio=$TORCHAUDIO_VERSION"
        echo "Reinstalling torchaudio to match torch version..."
        # Reinstall torchaudio from PyTorch CUDA index to match torch
        pip install --force-reinstall --no-deps \
            torchaudio==${TORCH_VERSION} \
            --index-url https://download.pytorch.org/whl/cu124 || {
            echo "ERROR: Failed to reinstall torchaudio from cu124 index"
            echo "Trying without CUDA suffix..."
            pip install --force-reinstall --no-deps torchaudio==${TORCH_BASE}
        }
    else
        echo "Versions match: torch=$TORCH_VERSION, torchaudio=$TORCHAUDIO_VERSION"
    fi

    # Verify the final versions
    echo "=== Final PyTorch package versions ==="
    python -c "import torch; import torchaudio; print('torch:', torch.__version__); print('torchaudio:', torchaudio.__version__); print('CUDA:', torch.cuda.is_available())"

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
