#!/bin/bash
set -e

current_dir=$(dirname "$(realpath "$0")")
cd $current_dir
source .env

# Set up a trap to call the error_exit function on ERR signal
trap 'error_exit "### ERROR ###"' ERR

# Define instances with their configurations
declare -A INSTANCES=(
    ["1"]="7005:/sd-comfy/:sd_comfy"
    ["2"]="7100:/com2/:sd_comfy2"
    ["3"]="7101:/com3/:sd_comfy3"
    ["4"]="7102:/com4/:sd_comfy4"
)

usage() {
    echo "Usage: $0 {start|stop|restart|status|install} [instance_number|all]"
    echo ""
    echo "Commands:"
    echo "  start    - Start ComfyUI instance(s)"
    echo "  stop     - Stop ComfyUI instance(s)"
    echo "  restart  - Restart ComfyUI instance(s)"
    echo "  status   - Show status of instance(s)"
    echo "  install  - Install/prepare environment only"
    echo ""
    echo "Instance numbers: 1, 2, 3, 4, 5, or 'all'"
    echo ""
    echo "Examples:"
    echo "  $0 start all      # Start all instances"
    echo "  $0 stop 2         # Stop instance 2"
    echo "  $0 restart 1 3 5  # Restart instances 1, 3, and 5"
    echo "  $0 status         # Show status of all instances"
}

setup_environment() {
    echo "### Setting up Stable Diffusion Comfy Environment ###"
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

        # Install requirements.txt (this will install torch, torchvision, torchaudio)
        pip install -r requirements.txt

        # Install additional dependencies that custom nodes require
        pip install opencv-python scikit-image piexif segment-anything
        # Install ComfyUI Manager and other custom node dependencies
        pip install GitPython toml rich uv matplotlib ultralytics lpips simpleeval

        # === VERSION CHECK AND FIX ===
        # Must happen AFTER all pip installs, as some packages (like ultralytics) can downgrade torch
        echo "=== Checking PyTorch/torchaudio version compatibility ==="
        TORCH_VERSION=$(python -c "import torch; print(torch.__version__)")
        TORCHAUDIO_VERSION=$(pip show torchaudio | grep "^Version:" | cut -d' ' -f2)
        echo "Detected torch version: $TORCH_VERSION"
        echo "Detected torchaudio version: $TORCHAUDIO_VERSION"

        TORCH_BASE=$(echo "$TORCH_VERSION" | cut -d'+' -f1)
        TORCHAUDIO_BASE=$(echo "$TORCHAUDIO_VERSION" | cut -d'+' -f1)

        if [[ "$TORCH_BASE" != "$TORCHAUDIO_BASE" ]]; then
            echo "WARNING: Version mismatch detected! torch=$TORCH_VERSION, torchaudio=$TORCHAUDIO_VERSION"
            echo "Reinstalling torchaudio to match torch version..."
            pip install --force-reinstall --no-deps \
                torchaudio==${TORCH_VERSION} \
                --index-url https://download.pytorch.org/whl/cu128 || {
                echo "ERROR: Failed to reinstall torchaudio from cu128 index"
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
}

get_instance_info() {
    local instance=$1
    local info=${INSTANCES[$instance]}
    if [[ -z "$info" ]]; then
        echo "Invalid instance number: $instance" >&2
        return 1
    fi
    
    IFS=':' read -r port path name <<< "$info"
    echo "$port:$path:$name"
}

start_instance() {
    local instance=$1
    local info
    info=$(get_instance_info "$instance") || return 1
    
    IFS=':' read -r port path name <<< "$info"
    local pidfile="/tmp/${name}.pid"
    
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        echo "Instance $instance (port $port) is already running (PID: $(cat "$pidfile"))"
        return 0
    fi
    
    echo "Starting ComfyUI instance $instance on port $port..."
    source $VENV_DIR/sd_comfy-env/bin/activate
    cd "$REPO_DIR"
    
    PYTHONUNBUFFERED=1 service_loop "python main.py --dont-print-server --highvram --port $port" > "$LOG_DIR/${name}.log" 2>&1 &
    echo $! > "$pidfile"
    
    echo "Started ComfyUI instance $instance (PID: $!, port $port)"
    if env | grep -q "PAPERSPACE"; then
        echo "Link: https://$PAPERSPACE_FQDN$path"
    fi
}

stop_instance() {
    local instance=$1
    local info
    info=$(get_instance_info "$instance") || return 1
    
    IFS=':' read -r port path name <<< "$info"
    local pidfile="/tmp/${name}.pid"
    
    # Kill strategy: Find the entire process tree for this instance and kill from top to bottom
    
    # Find python processes for this port
    local python_pids=$(ps aux | grep "python main.py.*--port $port" | grep -v grep | awk '{print $2}')
    
    # Build a list of all PIDs in the process tree for this instance
    local all_pids=""
    
    # For each python process, walk up the process tree to find all ancestors
    for python_pid in $python_pids; do
        if [[ -n "$python_pid" ]]; then
            # Add the python process itself
            all_pids="$all_pids $python_pid"
            
            # Walk up the process tree
            local current_pid=$python_pid
            while [[ -n "$current_pid" && "$current_pid" != "1" ]]; do
                parent_pid=$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')
                if [[ -n "$parent_pid" && "$parent_pid" != "1" ]]; then
                    # Check if this is a bash process (to avoid killing system processes)
                    local parent_cmd=$(ps -p "$parent_pid" -o comm= 2>/dev/null)
                    if [[ "$parent_cmd" == "bash" ]]; then
                        all_pids="$all_pids $parent_pid"
                    fi
                    current_pid=$parent_pid
                else
                    break
                fi
            done
        fi
    done
    
    # Remove duplicates and sort PIDs in reverse order (kill parents before children)
    all_pids=$(echo $all_pids | tr ' ' '\n' | sort -unr | tr '\n' ' ')
    
    if [[ -n "$all_pids" ]]; then
        echo "Stopping ComfyUI instance $instance (port $port)..."
        echo "Found process tree: $all_pids"
        
        # First try graceful kill
        for pid in $all_pids; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "  Killing PID: $pid"
                kill "$pid" 2>/dev/null || true
            fi
        done
        
        sleep 2
        
        # Force kill any remaining processes
        for pid in $all_pids; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "  Force killing PID: $pid"
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
    else
        echo "Instance $instance is not running"
    fi
    
    # Clean up PID file
    if [[ -f "$pidfile" ]]; then
        rm -f "$pidfile"
    fi
    
    # Final check
    sleep 1
    local final_check=$(ps aux | grep "python main.py.*--port $port" | grep -v grep | awk '{print $2}')
    if [[ -z "$final_check" ]]; then
        echo "Stopped ComfyUI instance $instance"
    else
        echo "Warning: Some processes may still be running for instance $instance"
        echo "Remaining PIDs: $final_check"
    fi
}

status_instance() {
    local instance=$1
    local info
    info=$(get_instance_info "$instance") || return 1
    
    IFS=':' read -r port path name <<< "$info"
    local pidfile="/tmp/${name}.pid"
    
    # Check if PID file exists and process is running
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        local pid=$(cat "$pidfile")
        echo "Instance $instance: RUNNING (PID: $pid, port $port)"
        if env | grep -q "PAPERSPACE"; then
            echo "  Link: https://$PAPERSPACE_FQDN$path"
        fi
        return 0
    fi
    
    # If no valid PID file, check for running processes by port
    local pids=$(ps aux | grep "python main.py.*--port $port" | grep -v grep | awk '{print $2}')
    
    if [[ -n "$pids" ]]; then
        echo "Instance $instance: RUNNING (port $port) - PIDs: $pids"
        echo "  Warning: No valid PID file found"
        if env | grep -q "PAPERSPACE"; then
            echo "  Link: https://$PAPERSPACE_FQDN$path"
        fi
        # Clean up stale PID file if exists
        [[ -f "$pidfile" ]] && rm -f "$pidfile"
    else
        echo "Instance $instance: STOPPED (port $port)"
        # Clean up stale PID file if exists
        [[ -f "$pidfile" ]] && rm -f "$pidfile"
    fi
}

restart_instance() {
    local instance=$1
    echo "Restarting ComfyUI instance $instance..."
    stop_instance "$instance"
    sleep 1
    start_instance "$instance"
}

process_instances() {
    local action=$1
    shift
    local instances=("$@")
    
    if [[ ${#instances[@]} -eq 0 || "${instances[0]}" == "all" ]]; then
        instances=(1 2 3 4 5)
    fi
    
    for instance in "${instances[@]}"; do
        if [[ ! "${INSTANCES[$instance]}" ]]; then
            echo "Invalid instance number: $instance"
            continue
        fi
        
        case $action in
            start)
                start_instance "$instance"
                ;;
            stop)
                stop_instance "$instance"
                ;;
            restart)
                restart_instance "$instance"
                ;;
            status)
                status_instance "$instance"
                ;;
        esac
        echo ""
    done
}

# Main script logic
if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

command=$1
shift

case $command in
    install)
        setup_environment
        echo "### Environment setup complete ###"
        ;;
    start)
        setup_environment
        process_instances start "$@"
        ;;
    stop)
        process_instances stop "$@"
        ;;
    restart)
        setup_environment
        process_instances restart "$@"
        ;;
    status)
        process_instances status "$@"
        ;;
    *)
        echo "Unknown command: $command"
        usage
        exit 1
        ;;
esac

echo "### Done ###"