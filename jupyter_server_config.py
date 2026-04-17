# Copied to $JUPYTER_CONFIG_DIR/jupyter_server_config.py at boot by the notebook
# startup command. Registers jupyter-server-proxy routes so
#   https://<fqdn>/sd-comfy/... -> ComfyUI on 127.0.0.1:7005
#   https://<fqdn>/com2/...     -> ComfyUI on 127.0.0.1:7100
#   https://<fqdn>/com3/...     -> ComfyUI on 127.0.0.1:7101
#   https://<fqdn>/com4/...     -> ComfyUI on 127.0.0.1:7102
# This replaces the old nginx-on-8888 routing; keeping jupyter on port 8888
# (default) is required — Paperspace's infra evicts any pod where port 8888
# isn't serving jupyter.
c.ServerApp.jpserver_extensions = {'jupyter_server_proxy': True}

# In jupyter-server-proxy 4.x, omitting `command` means "don't launch a process,
# just proxy to the existing listener on `port`". Do NOT use `command: None` —
# that fails the trait validation in 4.x with "expected a list or a callable".
c.ServerProxy.servers = {
    'sd-comfy': {'port': 7005, 'absolute_url': False},
    'com2':     {'port': 7100, 'absolute_url': False},
    'com3':     {'port': 7101, 'absolute_url': False},
    'com4':     {'port': 7102, 'absolute_url': False},
}
