#!/usr/bin/env python3
import json
import os
import random
import time
import urllib.error
import urllib.request


WARMUP_TARGETS = [
    {
        "name": "wai",
        "port": 7005,
        "checkpoint": "waiIllustriousSDXL_v160.safetensors",
        "lora": "dmd2_sdxl_4step_lora_fp16.safetensors",
        "cfg": 1.0,
        "sampler": "lcm",
        "scheduler": "exponential",
        "steps": 8,
        "resolutions": [(1024, 1024), (832, 1216)],
    },
    {
        "name": "pornmaster",
        "port": 7100,
        "checkpoint": "pornmaster_proSDXLV7.safetensors",
        "lora": "dmd2_sdxl_4step_lora_fp16.safetensors",
        "cfg": 1.0,
        "sampler": "lcm",
        "scheduler": "exponential",
        "steps": 8,
        "resolutions": [(1024, 1024), (832, 1216)],
    },
]


def log(message):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    print(f"[{timestamp}] {message}", flush=True)


def http_json(url, payload=None, timeout=30):
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def wait_until_ready(port, timeout_seconds=180):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            stats = http_json(f"http://127.0.0.1:{port}/system_stats", timeout=5)
            if stats:
                return True
        except Exception:
            pass
        time.sleep(2)
    return False


def build_sdxl_compile_workflow(checkpoint, lora_name, width, height, steps, sampler, scheduler, cfg):
    workflow = {
        "1": {
            "inputs": {
                "ckpt_name": checkpoint
            },
            "class_type": "CheckpointLoaderSimple"
        },
        "3": {
            "inputs": {
                "text": "1girl, solo, standing, outdoors, high quality, detailed",
                "clip": ["10", 1] if lora_name else ["1", 1]
            },
            "class_type": "CLIPTextEncode"
        },
        "4": {
            "inputs": {
                "text": "bad quality, worst quality, low quality, blurry",
                "clip": ["10", 1] if lora_name else ["1", 1]
            },
            "class_type": "CLIPTextEncode"
        },
        "5": {
            "inputs": {
                "seed": random.randint(1, 2**32 - 1),
                "steps": steps,
                "cfg": cfg,
                "sampler_name": sampler,
                "scheduler": scheduler,
                "denoise": 1.0,
                "model": ["50", 0],
                "positive": ["3", 0],
                "negative": ["4", 0],
                "latent_image": ["6", 0]
            },
            "class_type": "KSampler"
        },
        "6": {
            "inputs": {
                "width": width,
                "height": height,
                "batch_size": 1
            },
            "class_type": "EmptyLatentImage"
        },
        "7": {
            "inputs": {
                "samples": ["5", 0],
                "vae": ["1", 2]
            },
            "class_type": "VAEDecode"
        },
        "26": {
            "inputs": {
                "images": ["7", 0]
            },
            "class_type": "PreviewImage"
        },
        "50": {
            "inputs": {
                "model": ["10", 0] if lora_name else ["1", 0],
                "backend": "inductor"
            },
            "class_type": "TorchCompileModel"
        }
    }

    if lora_name:
        workflow["10"] = {
            "inputs": {
                "lora_name": lora_name,
                "strength_model": 1.0,
                "strength_clip": 1.0,
                "model": ["1", 0],
                "clip": ["1", 1]
            },
            "class_type": "LoraLoader"
        }

    return workflow


def queue_prompt(port, workflow):
    response = http_json(
        f"http://127.0.0.1:{port}/prompt",
        {"prompt": workflow},
        timeout=30,
    )
    return response.get("prompt_id")


def wait_for_completion(port, prompt_id, timeout_seconds=420):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        history = http_json(f"http://127.0.0.1:{port}/history/{prompt_id}", timeout=10)
        prompt_data = history.get(prompt_id)
        if prompt_data:
            status = prompt_data.get("status", {})
            status_str = status.get("status_str")
            if status_str == "error":
                return False, prompt_data
            outputs = prompt_data.get("outputs", {})
            for node_id in ("26", "9", "11"):
                if outputs.get(node_id, {}).get("images"):
                    return True, prompt_data
            if status_str == "success":
                return True, prompt_data
        time.sleep(1)
    return False, None


def warm_target(target):
    port = target["port"]
    if not wait_until_ready(port):
        log(f"{target['name']} port {port} did not become ready in time")
        return

    for width, height in target["resolutions"]:
        workflow = build_sdxl_compile_workflow(
            checkpoint=target["checkpoint"],
            lora_name=target.get("lora"),
            width=width,
            height=height,
            steps=target["steps"],
            sampler=target["sampler"],
            scheduler=target["scheduler"],
            cfg=target["cfg"],
        )
        start = time.time()
        try:
            prompt_id = queue_prompt(port, workflow)
            if not prompt_id:
                log(f"{target['name']} {width}x{height} failed to queue")
                continue
            ok, _ = wait_for_completion(port, prompt_id)
            elapsed = time.time() - start
            if ok:
                log(f"{target['name']} {width}x{height} warmup completed in {elapsed:.1f}s")
            else:
                log(f"{target['name']} {width}x{height} warmup failed after {elapsed:.1f}s")
        except urllib.error.HTTPError as err:
            log(f"{target['name']} {width}x{height} HTTP error {err.code}")
        except Exception as err:
            log(f"{target['name']} {width}x{height} warmup error: {err}")


def main():
    if os.getenv("COMFY_WARMUP_ENABLED", "1") == "0":
        log("Warmup disabled by COMFY_WARMUP_ENABLED=0")
        return

    log("Starting ComfyUI compile warmup for dedicated SDXL lanes")
    for target in WARMUP_TARGETS:
        warm_target(target)
    log("ComfyUI compile warmup finished")


if __name__ == "__main__":
    main()
