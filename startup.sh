#!/bin/bash
# startup.sh — minimal version for debugging why pid-1 command fails.
# Just start jupyter ASAP and log everything to /storage for post-mortem.
set +e

STARTUP_LOG="/storage/startup-$(hostname)-$(date -u +%H%M%S).log"
{
  echo "[$(date -u +%H:%M:%S)] startup.sh invoked, host=$(hostname) pid=$$"
  echo "PATH=$PATH"
  echo "USER=$(whoami)"
  echo "PWD=$(pwd)"
  echo "BASH_VERSION=$BASH_VERSION"
  echo "jupyter: $(command -v jupyter 2>&1)"
  echo "python3: $(command -v python3 2>&1)"
  echo "pip: $(command -v pip 2>&1)"
  echo "ls /notebooks:"
  ls /notebooks 2>&1 | head -10
  echo "/notebooks/startup.sh exists: $(test -f /notebooks/startup.sh && echo YES || echo NO)"
  echo "/notebooks/entry.sh exists: $(test -f /notebooks/entry.sh && echo YES || echo NO)"
  echo "about to install jupyter-server-proxy"
} >> "$STARTUP_LOG" 2>&1

pip install -q jupyter-server-proxy >> "$STARTUP_LOG" 2>&1
echo "[$(date -u +%H:%M:%S)] pip install done rc=$?" >> "$STARTUP_LOG"

mkdir -p /root/.jupyter
cat > /root/.jupyter/jupyter_server_config.py <<'PYEOF'
c.ServerApp.jpserver_extensions = {'jupyter_server_proxy': True}
c.ServerProxy.servers = {
    'sd-comfy': {'command': None, 'port': 7005, 'absolute_url': False},
    'com2':     {'command': None, 'port': 7100, 'absolute_url': False},
    'com3':     {'command': None, 'port': 7101, 'absolute_url': False},
    'com4':     {'command': None, 'port': 7102, 'absolute_url': False},
}
PYEOF
echo "[$(date -u +%H:%M:%S)] config written" >> "$STARTUP_LOG"

# Background entry.sh
(bash /notebooks/entry.sh > /tmp/entry_bg.log 2>&1) &
echo "[$(date -u +%H:%M:%S)] entry.sh spawned pid=$!" >> "$STARTUP_LOG"

echo "[$(date -u +%H:%M:%S)] exec'ing jupyter" >> "$STARTUP_LOG"
exec jupyter lab --allow-root --ip=0.0.0.0 --no-browser \
    --ServerApp.trust_xheaders=True \
    --ServerApp.disable_check_xsrf=False \
    --ServerApp.allow_remote_access=True \
    --ServerApp.allow_origin='*' \
    --ServerApp.allow_credentials=True
