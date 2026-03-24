#!/bin/bash
# Run comprehensive benchmarks after container restart
# Usage: bash run_benchmarks.sh [port]
# Default port: 7005 (instance 1)

PORT=${1:-7005}
echo "=== ComfyUI Benchmark Suite ==="
echo "Testing on port $PORT"
echo "Date: $(date)"
echo ""

# Wait for instance to be ready
echo "Waiting for ComfyUI to be ready..."
for i in $(seq 1 120); do
    if curl -s "http://localhost:$PORT/system_stats" > /dev/null 2>&1; then
        echo "Ready after ${i}s"
        break
    fi
    sleep 2
done

# Check optimization flags
echo ""
echo "=== Checking Active Optimizations ==="
LOG_FILE="/tmp/log/sd_comfy.log"
grep -i "sage\|fast\|attention\|fp8\|autotune\|cublas\|Using\|vram\|Device" "$LOG_FILE" 2>/dev/null | tail -15

echo ""
echo "=== Running Benchmarks ==="

# Stop all other instances for clean measurements
echo "Stopping instances 2-5 for clean benchmarks..."
cd /notebooks/sd_comfy
for i in 2 3 4 5; do
    bash manage.sh stop $i 2>/dev/null &
done
wait
sleep 5

# Run all benchmarks
ALL_RESULTS="/tmp/benchmark_all_results.json"
echo "[]" > "$ALL_RESULTS"

for test_name in baseline steps4 steps6 euler resolution hypersd lightning common; do
    echo ""
    echo ">>> Running test: $test_name"
    python3 /tmp/comfy_benchmark.py --port $PORT --runs 10 --warmup 3 --test $test_name 2>&1
    echo ""
done

echo ""
echo "=== Restarting other instances ==="
for i in 2 3 4 5; do
    bash manage.sh start $i 2>/dev/null &
done
wait

echo ""
echo "=== Benchmark Complete ==="
echo "Results saved to /tmp/benchmark_results.json"
