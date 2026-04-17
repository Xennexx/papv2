#!/bin/bash
# Don't exit on error

# ============================================================================
# READINESS FAST-PATH
# ----------------------------------------------------------------------------
# Paperspace's Kubernetes readiness probe times out at ~60s waiting for
# port 8888 to respond. nginx used to fit, but boot time has crept up
# (Ubuntu 22.04 apt index + nodejs setup + pip installs) and boots now
# ride right against the deadline. We bind :8888 with a tiny Python HTTP
# server immediately so the probe passes, then hand off to nginx once the
# real stack is ready. python3 and nginx are both pre-installed in the
# gradient-base image.
# ============================================================================
if command -v python3 >/dev/null 2>&1; then
    cat > /tmp/readiness_placeholder.py <<'PYEOF'
import http.server, socketserver, signal, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _ok(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
    def do_GET(self):  self._ok(); self.wfile.write(b'booting')
    def do_HEAD(self): self._ok()
    def do_POST(self): self._ok(); self.wfile.write(b'booting')
socketserver.TCPServer.allow_reuse_address = True
try:
    srv = socketserver.TCPServer(('0.0.0.0', 8888), H)
except OSError:
    # Port already bound (nginx beat us to it) — harmless, just exit.
    sys.exit(0)
def _shutdown(*_):
    try: srv.shutdown()
    except Exception: pass
    sys.exit(0)
signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT,  _shutdown)
srv.serve_forever()
PYEOF
    nohup python3 -u /tmp/readiness_placeholder.py \
        > /tmp/readiness_placeholder.log 2>&1 &
    echo $! > /tmp/readiness_placeholder.pid
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if (exec 3<>/dev/tcp/127.0.0.1/8888) 2>/dev/null; then
            exec 3>&- 2>/dev/null
            echo "[entry] readiness placeholder bound :8888"
            break
        fi
        sleep 0.25
    done
fi

# Pull latest code from GitHub as the very first thing so future fixes
# land on the next boot regardless of what blows up downstream.
if [ -d /notebooks/.git ]; then
    echo "[entry] Early git pull (before nginx/install)..."
    ( cd /notebooks \
        && git checkout -- . 2>/dev/null \
        && git pull origin master 2>&1 | tail -5 ) || true
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
  
  # Use Nginx to expose web app in Paperspace
  # nginx is pre-installed in gradient-base, so skip apt-get update/install
  # when it's already present. Saves ~5s on the critical boot path.
  if ! command -v nginx >/dev/null 2>&1; then
    echo "nginx not found; running apt-get update + install"
    apt-get update -o Acquire::Languages=none -o Acquire::Translation=none
    apt-get install -qq -y nginx > /dev/null
  fi

  cp /$WORKING_DIR/nginx/default /etc/nginx/sites-available/default
  cp /$WORKING_DIR/nginx/nginx.conf /etc/nginx/nginx.conf

  # Hand port 8888 off from the readiness placeholder to nginx.
  if [[ -f /tmp/readiness_placeholder.pid ]]; then
    kill -TERM "$(cat /tmp/readiness_placeholder.pid)" 2>/dev/null || true
    rm -f /tmp/readiness_placeholder.pid
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if ! (exec 3<>/dev/tcp/127.0.0.1/8888) 2>/dev/null; then break; fi
      exec 3>&- 2>/dev/null
      sleep 0.2
    done
  fi
  /usr/sbin/nginx


echo "Installing common dependencies"
# libcairo2-dev + pkg-config are required by pycairo which is pulled in by
# comfyui_controlnet_aux's requirements.txt. Without them pip fails and
# main.sh's `set -e` kills the whole boot before ComfyUI instance 1 starts.
apt-get install -qq -y curl jq git-lfs ninja-build \
    aria2 zip python3-venv python3-dev python3.10 \
    python3.10-venv python3.10-dev python3.10-tk \
    libcairo2-dev pkg-config > /dev/null
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

