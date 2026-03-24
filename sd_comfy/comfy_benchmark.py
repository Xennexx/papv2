#!/usr/bin/env python3
"""
ComfyUI Benchmark Script
Sends identical prompts to a specific instance and measures execution time.
Designed to test one instance at a time to avoid GPU contention.
"""
import json
import time
import urllib.request
import sys
import argparse
import random
from datetime import datetime

def create_workflow(checkpoint, lora, steps, sampler, scheduler, cfg, width=1024, height=1024, seed=None, use_taesd=False):
    """Create a ComfyUI API workflow."""
    if seed is None:
        seed = random.randint(0, 2**32 - 1)

    workflow = {
        "1": {
            "inputs": {"ckpt_name": checkpoint},
            "class_type": "CheckpointLoaderSimple"
        },
        "3": {
            "inputs": {
                "text": "1girl, solo, standing, outdoors, park, sunny day, casual clothes, high quality, detailed",
                "clip": ["10", 1]
            },
            "class_type": "CLIPTextEncode"
        },
        "4": {
            "inputs": {
                "text": "bad quality, worst quality, low quality, blurry",
                "clip": ["10", 1]
            },
            "class_type": "CLIPTextEncode"
        },
        "5": {
            "inputs": {
                "seed": seed,
                "steps": steps,
                "cfg": cfg,
                "sampler_name": sampler,
                "scheduler": scheduler,
                "denoise": 1.0,
                "model": ["10", 0],
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
                "vae": ["1", 2] if not use_taesd else ["20", 0]
            },
            "class_type": "VAEDecode"
        },
        "9": {
            "inputs": {
                "filename_prefix": "benchmark",
                "images": ["7", 0]
            },
            "class_type": "SaveImage"
        }
    }

    if lora:
        workflow["10"] = {
            "inputs": {
                "lora_name": lora,
                "strength_model": 1.0,
                "strength_clip": 1.0,
                "model": ["1", 0],
                "clip": ["1", 1]
            },
            "class_type": "LoraLoader"
        }
    else:
        # No lora - connect directly to checkpoint
        workflow["5"]["inputs"]["model"] = ["1", 0]
        workflow["3"]["inputs"]["clip"] = ["1", 1]
        workflow["4"]["inputs"]["clip"] = ["1", 1]
        if "10" in workflow:
            del workflow["10"]
        # Fix: need a node 10 reference or remap
        workflow["3"]["inputs"]["clip"] = ["1", 1]
        workflow["4"]["inputs"]["clip"] = ["1", 1]
        workflow["5"]["inputs"]["model"] = ["1", 0]

    if use_taesd:
        workflow["20"] = {
            "inputs": {
                "taesd_name": "taesdxl_decoder.safetensors"
            },
            "class_type": "VAELoader"  # Will need to adjust for TAESD
        }

    return workflow


def queue_prompt(workflow, port=7005):
    """Queue a prompt and return the prompt ID."""
    data = json.dumps({"prompt": workflow}).encode('utf-8')
    req = urllib.request.Request(
        f"http://localhost:{port}/prompt",
        data=data,
        headers={'Content-Type': 'application/json'}
    )
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        result = json.loads(resp.read())
        return result.get('prompt_id')
    except Exception as e:
        print(f"  Error queuing prompt: {e}")
        return None


def wait_for_completion(prompt_id, port=7005, timeout=120):
    """Wait for a prompt to complete and return execution time from server timestamps."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.urlopen(f"http://localhost:{port}/history/{prompt_id}", timeout=5)
            data = json.loads(req.read())
            if prompt_id in data:
                info = data[prompt_id]
                status = info.get('status', {})
                status_str = status.get('status_str', '')
                if status_str == 'success' or status.get('completed', False):
                    # Extract actual execution time from timestamps
                    msgs = status.get('messages', [])
                    times = {}
                    for msg in msgs:
                        if len(msg) >= 2 and isinstance(msg[1], dict):
                            times[msg[0]] = msg[1].get('timestamp', 0)
                    if 'execution_start' in times and 'execution_success' in times:
                        exec_time = (times['execution_success'] - times['execution_start']) / 1000.0
                        return exec_time
                    return time.time() - start  # fallback to wall clock
                if status_str == 'error':
                    print("[ERROR]", end=" ")
                    return -1
        except:
            pass
        time.sleep(0.5)
    return -1  # timeout


def run_benchmark(name, workflow, port, num_runs=5, warmup=2):
    """Run a benchmark with warmup and multiple iterations."""
    print(f"\n{'='*60}")
    print(f"Benchmark: {name}")
    print(f"Port: {port}, Runs: {num_runs}, Warmup: {warmup}")
    print(f"{'='*60}")

    times = []

    # Warmup runs
    for i in range(warmup):
        print(f"  Warmup {i+1}/{warmup}...", end=" ", flush=True)
        # Use different seed each run
        workflow["5"]["inputs"]["seed"] = random.randint(0, 2**32 - 1)
        pid = queue_prompt(workflow, port)
        if pid:
            t = wait_for_completion(pid, port)
            print(f"{t:.2f}s" if t > 0 else "FAILED")
        else:
            print("FAILED to queue")

    # Actual measurement runs
    for i in range(num_runs):
        print(f"  Run {i+1}/{num_runs}...", end=" ", flush=True)
        workflow["5"]["inputs"]["seed"] = random.randint(0, 2**32 - 1)
        pid = queue_prompt(workflow, port)
        if pid:
            t = wait_for_completion(pid, port)
            if t > 0:
                times.append(t)
                print(f"{t:.2f}s")
            else:
                print("FAILED")
        else:
            print("FAILED to queue")

    if times:
        avg = sum(times) / len(times)
        min_t = min(times)
        max_t = max(times)
        times_sorted = sorted(times)
        median = times_sorted[len(times_sorted)//2]
        print(f"\n  Results: avg={avg:.2f}s, median={median:.2f}s, min={min_t:.2f}s, max={max_t:.2f}s ({len(times)} successful runs)")
        return {'name': name, 'avg': avg, 'median': median, 'min': min_t, 'max': max_t, 'times': times, 'runs': len(times)}
    else:
        print(f"\n  All runs FAILED")
        return {'name': name, 'avg': -1, 'median': -1, 'min': -1, 'max': -1, 'times': [], 'runs': 0}


def main():
    parser = argparse.ArgumentParser(description='ComfyUI Benchmark')
    parser.add_argument('--port', type=int, default=7005, help='ComfyUI port')
    parser.add_argument('--runs', type=int, default=8, help='Number of measurement runs')
    parser.add_argument('--warmup', type=int, default=2, help='Number of warmup runs')
    parser.add_argument('--test', type=str, default='all', help='Which test to run: baseline, steps4, steps6, lightning, fp8, all')
    parser.add_argument('--checkpoint', type=str, default='waiIllustriousSDXL_v160.safetensors')
    args = parser.parse_args()

    results = []

    print(f"ComfyUI Benchmark - {datetime.now().isoformat()}")
    print(f"Target: localhost:{args.port}")

    # Test 1: Current baseline (8 steps, DMD2, LCM)
    if args.test in ['all', 'baseline']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="dmd2_sdxl_4step_lora_fp16.safetensors",
            steps=8, sampler="lcm", scheduler="exponential", cfg=1.0,
            width=1024, height=1024
        )
        results.append(run_benchmark("Baseline: DMD2 8-step LCM", wf, args.port, args.runs, args.warmup))

    # Test 2: DMD2 with 4 steps
    if args.test in ['all', 'steps4']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="dmd2_sdxl_4step_lora_fp16.safetensors",
            steps=4, sampler="lcm", scheduler="exponential", cfg=1.0,
            width=1024, height=1024
        )
        results.append(run_benchmark("DMD2 4-step LCM", wf, args.port, args.runs, args.warmup))

    # Test 3: DMD2 with 6 steps
    if args.test in ['all', 'steps6']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="dmd2_sdxl_4step_lora_fp16.safetensors",
            steps=6, sampler="lcm", scheduler="exponential", cfg=1.0,
            width=1024, height=1024
        )
        results.append(run_benchmark("DMD2 6-step LCM", wf, args.port, args.runs, args.warmup))

    # Test 4: DMD2 with euler sampler
    if args.test in ['all', 'euler']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="dmd2_sdxl_4step_lora_fp16.safetensors",
            steps=4, sampler="euler", scheduler="normal", cfg=1.0,
            width=1024, height=1024
        )
        results.append(run_benchmark("DMD2 4-step Euler", wf, args.port, args.runs, args.warmup))

    # Test 5: Different resolutions
    if args.test in ['all', 'resolution']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="dmd2_sdxl_4step_lora_fp16.safetensors",
            steps=8, sampler="lcm", scheduler="exponential", cfg=1.0,
            width=832, height=1152
        )
        results.append(run_benchmark("Baseline 832x1152", wf, args.port, args.runs, args.warmup))

    # Test 6: Hyper-SDXL LoRA 4 steps
    if args.test in ['all', 'hypersd']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="Hyper-SDXL-4steps-lora.safetensors",
            steps=4, sampler="euler", scheduler="normal", cfg=1.0,
            width=1024, height=1024
        )
        results.append(run_benchmark("Hyper-SDXL 4-step Euler", wf, args.port, args.runs, args.warmup))

    # Test 7: SDXL Lightning LoRA 4 steps
    if args.test in ['all', 'lightning']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="sdxl_lightning_4step_lora.safetensors",
            steps=4, sampler="euler", scheduler="sgm_uniform", cfg=1.0,
            width=1024, height=1024
        )
        results.append(run_benchmark("SDXL Lightning 4-step", wf, args.port, args.runs, args.warmup))

    # Test 8: DMD2 4-step at 832x1216 (most common resolution)
    if args.test in ['all', 'common']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="dmd2_sdxl_4step_lora_fp16.safetensors",
            steps=4, sampler="lcm", scheduler="exponential", cfg=1.0,
            width=832, height=1216
        )
        results.append(run_benchmark("DMD2 4-step 832x1216", wf, args.port, args.runs, args.warmup))

    # Test 9: PCM (Phased Consistency Model) 4 steps
    if args.test in ['all', 'pcm']:
        wf = create_workflow(
            checkpoint=args.checkpoint,
            lora="pcm_sdxl_normalcfg_4step_converted.safetensors",
            steps=4, sampler="euler", scheduler="normal", cfg=4.0,
            width=1024, height=1024
        )
        results.append(run_benchmark("PCM 4-step Euler CFG4", wf, args.port, args.runs, args.warmup))

    # Summary
    print(f"\n{'='*60}")
    print("BENCHMARK SUMMARY")
    print(f"{'='*60}")
    for r in results:
        if r['avg'] > 0:
            print(f"  {r['name']:40s} avg={r['avg']:.2f}s  median={r['median']:.2f}s  (n={r['runs']})")
        else:
            print(f"  {r['name']:40s} FAILED")

    # Save results
    with open('/tmp/benchmark_results.json', 'w') as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to /tmp/benchmark_results.json")

    return results

if __name__ == '__main__':
    main()
