#!/bin/bash
# Don't exit on error

# entry.sh now runs in the background (spawned by the Paperspace notebook
# command alongside jupyter lab on port 8888). Jupyter itself binds :8888,
# so we no longer need the old readiness placeholder or nginx. entry.sh's
# only responsibility is to set up + launch the ComfyUI instances on the
# internal ports (7005/7100/7101/7102). jupyter-server-proxy handles the
# external /sd-comfy/, /com2/, /com3/, /com4/ routing.

# Pull latest code from GitHub as the very first thing so future fixes
# land on the next boot regardless of what blows up downstream. MUST be
# time-bounded — a hung git pull here stalls the entire boot and leaves
# the placeholder serving while nginx never starts.
if [ -d /notebooks/.git ]; then
    echo "[entry] Early git pull (30s timeout)..."
    ( cd /notebooks \
        && git checkout -- . 2>/dev/null \
        && timeout 30 git pull origin master 2>&1 | tail -5 ) || \
        echo "[entry] git pull timed out or failed; continuing with on-disk code"
fi

# Ensure jupyter-server-proxy is present in the SYSTEM python that runs jupyter.
# Older cached gradient-base images preinstalled it; newer image pulls (e.g. fresh
# accounts) omit it, so jupyter's /sd-comfy /com2 /com3 /com4 proxy routes never
# register (-> 404) even though ComfyUI serves fine on localhost. jupyter is launched
# in parallel with this script by the notebook command, so if jsp was missing we must
# install it AND restart jupyter (from /notebooks, with the config) for the extension +
# routes to load. No-op on boxes that already have it (no jupyter restart, no disruption).
if command -v /usr/local/bin/python3 >/dev/null 2>&1 && ! /usr/local/bin/python3 -c "import jupyter_server_proxy" 2>/dev/null; then
    echo "[entry] jupyter-server-proxy missing in system python — installing 4.5.0 + restarting jupyter"
    /usr/local/bin/python3 -m pip install jupyter-server-proxy==4.5.0 >/tmp/jsp_install.log 2>&1
    pkill -f jupyter-lab 2>/dev/null; sleep 2
    ( cd /notebooks && setsid bash -c "jupyter lab --config=/notebooks/jupyter_server_config.py --allow-root --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.trust_xheaders=True --ServerApp.disable_check_xsrf=False --ServerApp.allow_remote_access=True --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True" >/tmp/jup_jsp_restart.log 2>&1 </dev/null & )
fi

# Deathwatch: log resource state every 10s to /storage so we can post-mortem
# any pod kill. Safe to run everywhere because /storage is persistent.
if command -v python3 >/dev/null 2>&1; then
    cat > /tmp/deathwatch.py <<'PYEOF'
import os, time, signal
HOSTNAME = os.environ.get("HOSTNAME", "unknown")
START_TS = time.strftime("%Y%m%d_%H%M%S")
LOGPATH = f"/storage/deathwatch-{HOSTNAME}-{START_TS}.log"
def read_first(p):
    try: return open(p).read().strip()
    except Exception: return None
def top_procs(n=6):
    procs = []
    try:
        for d in os.listdir('/proc'):
            if not d.isdigit(): continue
            try:
                st = open(f'/proc/{d}/status').read()
                rss = next((l for l in st.splitlines() if l.startswith('VmRSS:')), None)
                if rss:
                    rss_kb = int(rss.split()[1])
                    cmdline = open(f'/proc/{d}/cmdline').read().replace(chr(0),' ')[:100]
                    procs.append((rss_kb, d, cmdline))
            except Exception: continue
    except Exception: pass
    procs.sort(reverse=True)
    return procs[:n]
def cg_mem():
    vals={}
    for base in ('/sys/fs/cgroup','/sys/fs/cgroup/memory'):
        for fname in ('memory.current','memory.max','memory.peak','memory.events'):
            v=read_first(f"{base}/{fname}")
            if v and fname not in vals: vals[fname]=v.replace('\n',' ')
    return vals
def meminfo():
    info={}
    try:
        for l in open('/proc/meminfo'):
            k,v=l.split(':',1); info[k.strip()]=v.strip().split()[0]
    except Exception: pass
    return info
stop=False
def sig(*_):
    global stop; stop=True
signal.signal(signal.SIGTERM, sig); signal.signal(signal.SIGINT, sig)
with open(LOGPATH,'w',buffering=1) as f:
    f.write(f"=== start {time.strftime('%Y-%m-%d %H:%M:%S')} host={HOSTNAME} ===\n")
    try: f.write(f"pid1: {open('/proc/1/cmdline').read().replace(chr(0),' ')}\n")
    except: pass
    i=0
    while not stop:
        i+=1
        mi=meminfo(); cg=cg_mem()
        ts=time.strftime('%H:%M:%S')
        f.write(f"[{ts}] t={i} MemAvail={mi.get('MemAvailable','?')}kB "
                f"cg_cur={cg.get('memory.current','?')} cg_max={cg.get('memory.max','?')} "
                f"cg_peak={cg.get('memory.peak','?')} cg_events={cg.get('memory.events','?')}\n")
        for rss,pid,cmd in top_procs(6):
            f.write(f"        #{pid} rss={rss:>10}kB {cmd}\n")
        for _ in range(10):
            if stop: break
            time.sleep(1)
    f.write(f"=== stop graceful {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
PYEOF
    nohup python3 /tmp/deathwatch.py > /dev/null 2>&1 &
    echo "[entry] deathwatch spawned pid=$!"
fi

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

  # No nginx/placeholder anymore — jupyter owns :8888 and jupyter-server-proxy
  # fans out /sd-comfy/, /com2/, /com3/, /com4/ to the ComfyUI instances.



# ──────────────────────────────────────────────────────────────────────
# APT mirror failover (added 2026-05-05 after pap1+pap2 boots deadlocked
# on Canonical mirror egress). Probes archive.ubuntu.com on a fast
# timeout; if unreachable, swaps sources.list (and sources.list.d/*) to
# the first reachable fallback. mirrors.edge.kernel.org carries both the
# archive AND security suites and was the only Canonical-adjacent mirror
# that stayed reachable from these specific pods that day. Idempotent —
# no-op when archive.ubuntu.com is healthy.
# ──────────────────────────────────────────────────────────────────────
ensure_apt_mirror_reachable() {
    if timeout 6 curl -4 -sf -o /dev/null \
        "http://archive.ubuntu.com/ubuntu/dists/jammy/Release"; then
        return 0
    fi
    echo "[entry] archive.ubuntu.com unreachable; trying fallback mirrors..."
    local fallback=""
    for cand in mirrors.edge.kernel.org de.archive.ubuntu.com nl.archive.ubuntu.com; do
        if timeout 6 curl -4 -sf -o /dev/null \
            "http://$cand/ubuntu/dists/jammy/Release"; then
            fallback="$cand"; break
        fi
    done
    if [ -z "$fallback" ]; then
        echo "[entry] WARN: no fallback mirror reachable — apt will likely fail"
        return 1
    fi
    echo "[entry] swapping apt mirrors -> $fallback"
    [ -f /etc/apt/sources.list.entry-bak ] || cp /etc/apt/sources.list /etc/apt/sources.list.entry-bak
    find /etc/apt/sources.list /etc/apt/sources.list.d -type f \( -name '*.list' -o -name 'sources.list' \) 2>/dev/null \
      | while read f; do
            sed -i \
                -e "s|http://archive\.ubuntu\.com|http://$fallback|g" \
                -e "s|http://security\.ubuntu\.com|http://$fallback|g" \
                -e "s|http://us\.archive\.ubuntu\.com|http://$fallback|g" \
                "$f"
        done
    cat > /etc/apt/apt.conf.d/99entry-failover <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "5";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
EOF
}
ensure_apt_mirror_reachable

echo "Installing common dependencies"
# apt-get update is required — the base container's apt cache points at old
# package versions that security.ubuntu.com has already rotated out, so
# installing python3.10-venv etc. 404s without a fresh update. A stale cache
# silently breaks the entire boot: main.sh rm -rf's /storage/sd_comfy-env
# then tries `python3.10 -m venv` which fails because python3.10-venv never
# got installed, main2/3/4 time out waiting for the .prepared marker.
# Time-bounded so a hung mirror can't stall the whole boot.
timeout 60 apt-get update -qq > /dev/null 2>&1 || \
    echo "[entry] apt-get update timed out or failed; continuing (install may 404)"
# libcairo2-dev + pkg-config are required by pycairo which is pulled in by
# comfyui_controlnet_aux's requirements.txt. Without them pip fails and
# main.sh's `set -e` kills the whole boot before ComfyUI instance 1 starts.
timeout 300 apt-get install -qq -y --fix-missing curl jq git-lfs ninja-build \
    aria2 zip python3-venv python3-dev python3.10 \
    python3.10-venv python3.10-dev python3.10-tk \
    libcairo2-dev pkg-config > /dev/null
timeout 60 apt-get install -y htop > /dev/null

# Update Node.js to version 20.x
echo "Updating Node.js to version 20.x"
timeout 30 apt-get remove -y nodejs > /dev/null 2>&1 || true
timeout 180 bash -c 'curl -fsSL https://deb.nodesource.com/setup_20.x | bash -' > /dev/null
timeout 180 apt-get install -y nodejs > /dev/null

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

# (git pull already ran at the top of entry.sh as part of the readiness
# fast-path, so the on-disk code is up-to-date before main.sh runs.)

bash /notebooks/sd_comfy/main.sh
bash /notebooks/sd_comfy/main2.sh
bash /notebooks/sd_comfy/main3.sh
bash /notebooks/sd_comfy/main4.sh

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

