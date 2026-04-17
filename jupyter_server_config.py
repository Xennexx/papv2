# Copied to /root/.jupyter/jupyter_server_config.py at boot by the notebook
# startup command. Registers jupyter-server-proxy routes so
#   https://<fqdn>/sd-comfy/... -> ComfyUI on 127.0.0.1:7005
#   https://<fqdn>/com2/...     -> ComfyUI on 127.0.0.1:7100
#   https://<fqdn>/com3/...     -> ComfyUI on 127.0.0.1:7101
#   https://<fqdn>/com4/...     -> ComfyUI on 127.0.0.1:7102
# This replaces the old nginx-on-8888 routing; keeping jupyter on port 8888
# (default) is required — Paperspace's sidecar crashes if pid 1 isn't jupyter.
c.ServerApp.jpserver_extensions = {'jupyter_server_proxy': True}

c.ServerProxy.servers = {
    'sd-comfy': {'command': None, 'port': 7005, 'absolute_url': False},
    'com2':     {'command': None, 'port': 7100, 'absolute_url': False},
    'com3':     {'command': None, 'port': 7101, 'absolute_url': False},
    'com4':     {'command': None, 'port': 7102, 'absolute_url': False},
}
