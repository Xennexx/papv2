#!/bin/bash
set -e

current_dir=$(dirname "$(realpath "$0")")
cd $current_dir
source .env

# Set up a trap to call the error_exit function on ERR signal
trap 'error_exit "### ERROR ###"' ERR

ensure_custom_node_repo() {
  local repo_url="$1"
  local dir_name="$2"
  local requirements_file="${3:-}"
  local node_dir="$REPO_DIR/custom_nodes/$dir_name"
  local requirements_marker="$node_dir/.requirements_installed"

  mkdir -p "$REPO_DIR/custom_nodes"

  if [[ ! -d "$node_dir" ]]; then
    echo "Installing $dir_name custom node..."
    git clone "$repo_url" "$node_dir"
  fi

  if [[ -n "$requirements_file" && -f "$node_dir/$requirements_file" && ! -f "$requirements_marker" ]]; then
    echo "Installing dependencies for $dir_name..."
    pip install -r "$node_dir/$requirements_file" --extra-index-url https://pypi.org/simple
    touch "$requirements_marker"
  fi
}

# Single source of truth: "<repo_url>|<dir_name>|<requirements_file_or_empty>".
# ComfyUI_ADV_CLIP_emb provides BNK_CLIPTextEncodeAdvanced (the positive/negative
# prompt encoders in the main gen path). It was historically missing from this
# list — fresh boxes (acc5) came up without it and 400'd every standard gen
# while still looking "up" (incident 2026-05-27). Add new required nodes here.
REQUIRED_CUSTOM_NODES=(
  "https://github.com/chengzeyi/Comfy-WaveSpeed.git|Comfy-WaveSpeed|"
  "https://github.com/Fannovel16/comfyui_controlnet_aux.git|comfyui_controlnet_aux|requirements.txt"
  "https://github.com/rgthree/rgthree-comfy.git|rgthree-comfy|"
  "https://github.com/BlenderNeko/ComfyUI_ADV_CLIP_emb.git|ComfyUI_ADV_CLIP_emb|"
)

ensure_required_custom_nodes() {
  local spec url dir req
  for spec in "${REQUIRED_CUSTOM_NODES[@]}"; do
    IFS='|' read -r url dir req <<< "$spec"
    ensure_custom_node_repo "$url" "$dir" "$req"
  done
}

# Fail loud: refuse to start a misprovisioned box. A node dir that is absent or
# never loaded (no __init__.py) means ComfyUI silently won't register its nodes,
# which surfaces only as per-gen 400s once the box is already taking traffic.
verify_required_custom_nodes() {
  local spec url dir req missing=()
  for spec in "${REQUIRED_CUSTOM_NODES[@]}"; do
    IFS='|' read -r url dir req <<< "$spec"
    if [[ ! -f "$REPO_DIR/custom_nodes/$dir/__init__.py" ]]; then
      missing+=("$dir")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    error_exit "### ERROR ### Required ComfyUI custom node(s) missing/unloadable after install: ${missing[*]} (under $REPO_DIR/custom_nodes). Refusing to start — a box without these 400s every standard generation. Fix the clone (network/git) and re-run."
  fi
  echo "Verified ${#REQUIRED_CUSTOM_NODES[@]} required custom nodes present."
}


echo "### Setting up Stable Diffusion Comfy ###"
log "Setting up Stable Diffusion Comfy"

# Force reinstall if torch has wrong CUDA version for this driver
if [[ -f "$VENV_DIR/sd_comfy-env/.prepared" ]] && [[ -f "$VENV_DIR/sd_comfy-env/bin/activate" ]]; then
    source $VENV_DIR/sd_comfy-env/bin/activate
    TORCH_CUDA=$( python -c "import torch; print(torch.version.cuda or '')" 2>/dev/null || echo "")
    deactivate 2>/dev/null || true
    if [[ "$TORCH_CUDA" != 12.6* ]]; then
        echo "WARNING: Installed torch uses CUDA $TORCH_CUDA but need 12.6 — forcing reinstall"
        rm -f $VENV_DIR/sd_comfy-env/.prepared
    fi
fi

if [[ "$REINSTALL_SD_COMFY" || ! -f "$VENV_DIR/sd_comfy-env/.prepared" ]]; then

    
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
    # Pinned to the versions running on the working boxes (acc1-4). Unpinned was
    # resolving to torch 2.12.0, which has no matching torchaudio on the cu126
    # index -> version-mismatch fix-up fails -> main.sh dies before touch .prepared
    # -> instances 2/3/4 time out. Keep these in lockstep.
    pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url https://download.pytorch.org/whl/cu126
    pip install xformers==0.0.35 --index-url https://download.pytorch.org/whl/cu126

    # Install requirements.txt — use cu126 as primary index so pip doesn't pull cu130 from PyPI
    pip install -r requirements.txt --index-url https://download.pytorch.org/whl/cu126 --extra-index-url https://pypi.org/simple
    # Install additional dependencies that custom nodes require
    pip install opencv-python scikit-image piexif segment-anything
    # Install ComfyUI Manager and other custom node dependencies
    pip install GitPython toml rich uv matplotlib lpips simpleeval
    # Custom node dependencies
    pip install deepdiff timm numba pynvml addict
    # Install ultralytics deps first, then ultralytics with --no-deps to prevent torch downgrade
    pip install requests polars scipy ultralytics-thop pandas psutil py-cpuinfo seaborn
    pip install ultralytics --no-deps
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
            --index-url https://download.pytorch.org/whl/cu126 || {
            echo "ERROR: Failed to reinstall torchaudio from cu126 index"
            echo "Trying without CUDA suffix..."
            pip install --force-reinstall --no-deps torchaudio==${TORCH_BASE}
        }
    else
        echo "Versions match: torch=$TORCH_VERSION, torchaudio=$TORCHAUDIO_VERSION"
    fi

    # Verify the final versions
    echo "=== Final PyTorch package versions ==="
    python -c "import torch; import torchaudio; print('torch:', torch.__version__); print('torchaudio:', torchaudio.__version__); print('CUDA:', torch.cuda.is_available())"

    touch $VENV_DIR/sd_comfy-env/.prepared
else
    
    source $VENV_DIR/sd_comfy-env/bin/activate
    
fi
log "Finished Preparing Environment for Stable Diffusion Comfy"

ensure_required_custom_nodes
verify_required_custom_nodes

if [[ -z "$INSTALL_ONLY" ]]; then
  echo "### Starting Stable Diffusion Comfy ###"
  log "Starting Stable Diffusion Comfy"

  cd "$REPO_DIR"

  # Fix tinyterraNodes duplicate config option that prevents it from loading
  TINYTERRA_CONFIG="$REPO_DIR/custom_nodes/ComfyUI_tinyterraNodes/config.ini"
  if [[ -f "$TINYTERRA_CONFIG" ]]; then
    awk '!seen[$0]++' "$TINYTERRA_CONFIG" > "${TINYTERRA_CONFIG}.tmp" && mv "${TINYTERRA_CONFIG}.tmp" "$TINYTERRA_CONFIG"
  fi

  PYTHONUNBUFFERED=1 service_loop "python main.py --dont-print-server --highvram --fast --preview-method none --port 7005" > $LOG_DIR/sd_comfy.log 2>&1 &
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
