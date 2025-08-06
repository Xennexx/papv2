#!/bin/bash
# Don't exit on error

function source_env_file() {
  if [[ -e ".env" ]]; then
    source ".env"
  fi
}

function check_required_env_vars() {
  local required_vars=($(echo "$REQUIRED_ENV" | tr ',' '\n'))
  local missing_vars=()
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
      missing_vars+=("$var")
    fi
  done
  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "The following required environment variables are missing: ${missing_vars[*]}"
    return 1
  fi
  return 0
}

export SCRIPT_ROOT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
cd $SCRIPT_ROOT_DIR
source_env_file

# Prepare Path (for local install)
mkdir -p $DATA_DIR
mkdir -p $WORKING_DIR
mkdir -p $ROOT_REPO_DIR
mkdir -p $VENV_DIR
mkdir -p $LOG_DIR


  # Add alias to check the status of the web app
  chmod +x $WORKING_DIR/status_check.py
  echo "alias status='watch -n 1 /$WORKING_DIR/status_check.py'" >> ~/.bashrc
  
  # Use Nginx to expose web app in Paperspace
  echo "Running update apt-get before installing nginx"
  apt-get update -o Acquire::Languages=none -o Acquire::Translation=none
  echo "Now installing nginx"
  apt-get install -qq -y nginx > /dev/null
  echo "Installed nginx"
  
  cp /$WORKING_DIR/nginx/default /etc/nginx/sites-available/default
  cp /$WORKING_DIR/nginx/nginx.conf /etc/nginx/nginx.conf
  /usr/sbin/nginx


echo "Installing common dependencies"
apt-get update
apt-get install -qq -y curl jq git-lfs ninja-build \
    aria2 zip python3-venv python3-dev python3.10 \
    python3.10-venv python3.10-dev python3.10-tk  > /dev/null
/usr/local/bin/python -m pip install einops > /dev/null
/usr/local/bin/python -m pip install torchsde > /dev/null
/usr/local/bin/python -m pip install spandrel
/usr/local/bin/python -m pip install kornia
apt-get install -y htop > /dev/null

# Update Node.js to version 20.x
echo "Updating Node.js to version 20.x"
apt-get remove -y nodejs > /dev/null 2>&1 || true
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null
apt-get install -y nodejs > /dev/null

# Install PM2 globally
echo "Installing PM2 for process management"
npm install -g pm2 > /dev/null 2>&1



# Read the RUN_SCRIPT environment variable
run_script="$RUN_SCRIPT"

# Separate the variable by commas
IFS=',' read -ra scripts <<< "$run_script"

# Prepare required path
mkdir -p $IMAGE_OUTPUTS_DIR
if [[ ! -d $WORKING_DIR/image_outputs ]]; then
  ln -s $IMAGE_OUTPUTS_DIR $WORKING_DIR/image_outputs
fi

# Update Node.js to version 20.x (ensure latest)
echo "Updating Node.js to version 20.x"
apt-get remove -y nodejs > /dev/null 2>&1 || true
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null
apt-get install -y nodejs > /dev/null

# Install important Python dependencies for ComfyUI
echo "Installing Python dependencies for ComfyUI"
pip install opencv-python scikit-image piexif segment-anything > /dev/null

bash /notebooks/sd_comfy/main.sh
bash /notebooks/sd_comfy/main2.sh
bash /notebooks/sd_comfy/main3.sh
bash /notebooks/sd_comfy/main4.sh

# Install PM2 globally (ensure it's available)
echo "Installing PM2 for process management"
npm install -g pm2 > /dev/null 2>&1

# Start background services with PM2 using robust startup script
echo "Starting ComfyUI background services with PM2..."

# Use the robust startup script if it exists
if [ -f /notebooks/sd_comfy/start_pm2_services.sh ]; then
    chmod +x /notebooks/sd_comfy/start_pm2_services.sh
    echo "Running PM2 startup script in background to avoid blocking entry.sh..."
    nohup bash /notebooks/sd_comfy/start_pm2_services.sh > /tmp/pm2_startup.log 2>&1 &
    echo "PM2 startup initiated (check /tmp/pm2_startup.log for details)"
else
    echo "WARNING: PM2 startup script not found, using fallback method..."
    # Fallback to basic method if script doesn't exist
    cd /notebooks/sd_comfy
    chmod +x auto_restart.js image_cleanup.js
    
    # Set PM2 home to persistent location
    export PM2_HOME=/notebooks/.pm2_config
    mkdir -p $PM2_HOME
    
    # Kill any existing PM2 daemon first to ensure clean start
    pm2 kill > /dev/null 2>&1 || true
    
    # Start PM2 daemon fresh
    pm2 status > /dev/null 2>&1
    
    # Start the processes
    echo "Starting auto-restart service..."
    pm2 start /notebooks/sd_comfy/auto_restart.js \
        --name "comfyui-auto-restart" \
        --cwd /notebooks/sd_comfy \
        --max-memory-restart 500M \
        --time
    
    echo "Starting image cleanup service..."
    pm2 start /notebooks/sd_comfy/image_cleanup.js \
        --name "comfyui-image-cleanup" \
        --cwd /notebooks/sd_comfy \
        --max-memory-restart 500M \
        --time
    
    # Save the process list
    pm2 save --force
    
    # Show the running processes
    echo "PM2 processes started:"
    pm2 list
fi

# Loop through each script and execute the corresponding case
echo "Starting script(s)"
for script in "${scripts[@]}"
do
  cd $SCRIPT_ROOT_DIR
  if [[ ! -d $script ]]; then
    echo "Script folder $script not found, skipping..."
    continue
  fi
  cd $script
  source_env_file
  if ! check_required_env_vars; then
    echo "One or more required environment variables are missing."
    continue
  fi
  bash control.sh reload

done

