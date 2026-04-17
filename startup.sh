#!/bin/bash
# startup.sh — runs as pid 1 on pod start (via Paperspace notebook "command").
#
# Key architectural decision: keep jupyter on default port 8888 because
# Paperspace's infra evicts any pod that replaces jupyter-on-:8888 with nginx
# (empirically confirmed). We use jupyter-server-proxy to expose /sd-comfy/,
# /com2/, /com3/, /com4/ through jupyter to the ComfyUI instances on
# 7005/7100/7101/7102.
set +e

# Persistent log so we can post-mortem even if pid 1 exits before jupyter binds.
STARTUP_LOG="/storage/startup-$(hostname)-$(date -u +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$STARTUP_LOG") 2>&1
echo "[startup] $(date -u +%H:%M:%S) host=$(hostname) begin"
echo "[startup] PATH=$PATH"
echo "[startup] which jupyter: $(which jupyter 2>&1)"
echo "[startup] which pip: $(which pip 2>&1)"
echo "[startup] /notebooks contents:"
ls /notebooks 2>&1 | head -20

echo "[startup] $(date -u +%H:%M:%S) installing jupyter-server-proxy..."
pip install -q jupyter-server-proxy 2>&1 | tail -3
echo "[startup] pip install rc=$?"

echo "[startup] $(date -u +%H:%M:%S) writing jupyter_server_config.py..."
mkdir -p /root/.jupyter
cat > /root/.jupyter/jupyter_server_config.py <<'PYEOF'
c.ServerApp.jpserver_extensions = {'jupyter_server_proxy': True}
c.ServerProxy.servers = {
    'sd-comfy': {'command': None, 'port': 7005, 'absolute_url': False,
                 'request_headers_override': {'Host': '127.0.0.1:7005'}},
    'com2':     {'command': None, 'port': 7100, 'absolute_url': False,
                 'request_headers_override': {'Host': '127.0.0.1:7100'}},
    'com3':     {'command': None, 'port': 7101, 'absolute_url': False,
                 'request_headers_override': {'Host': '127.0.0.1:7101'}},
    'com4':     {'command': None, 'port': 7102, 'absolute_url': False,
                 'request_headers_override': {'Host': '127.0.0.1:7102'}},
}
PYEOF
echo "[startup] config written, ls /root/.jupyter:"
ls /root/.jupyter 2>&1

echo "[startup] $(date -u +%H:%M:%S) kicking entry.sh in background..."
( bash /notebooks/entry.sh > /tmp/entry_bg.log 2>&1 ) &
ENTRY_PID=$!
echo "[startup] entry.sh pid=$ENTRY_PID"

echo "[startup] $(date -u +%H:%M:%S) exec'ing jupyter lab on :8888..."
exec env PIP_DISABLE_PIP_VERSION_CHECK=1 jupyter lab \
    --allow-root --ip=0.0.0.0 --no-browser \
    --ServerApp.trust_xheaders=True \
    --ServerApp.disable_check_xsrf=False \
    --ServerApp.allow_remote_access=True \
    --ServerApp.allow_origin='*' \
    --ServerApp.allow_credentials=True
