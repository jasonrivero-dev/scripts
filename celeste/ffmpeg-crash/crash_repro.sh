#!/usr/bin/env bash
# Manual GPU-box verification for SW-3035. Not part of ctest/CI (no GPU there).
#
# Starts a real recording via crash_repro_helper, SIGKILLs it mid-write to simulate a
# crash/power-loss, then checks whether the resulting file is still a valid, demuxable
# MP4. Expected: FAILs before the fragmented-MP4 fix in Init(), PASSes after.
#
# Invoked by run.sh from celeste's back_end/cmake-build-relwithdebinfo, after it stages
# and builds crash_repro_helper there. NOT via Docker: run_docker() passes no --gpus
# flag, so the container never sees the GPU.

set -e

if ! command -v nvidia-smi >/dev/null || ! nvidia-smi -L >/dev/null 2>&1; then
    echo "FAIL: no NVIDIA GPU detected (nvidia-smi unavailable or failed) -- this repro requires real NVENC hardware." >&2
    exit 1
fi
echo "GPU: $(nvidia-smi -L)"

OUT="/tmp/crash_repro_test.mp4"
rm -f "$OUT"

./test/crash_repro_helper "$OUT" &
PID=$!

sleep 6 # let Init() finish and several fragments/keyframes flush

kill -9 "$PID"
wait "$PID" 2>/dev/null || true

if ffprobe -v error -show_format -show_streams "$OUT" >/dev/null 2>&1; then
    echo "PASS: file is valid after forced kill ($OUT)"
    exit 0
else
    echo "FAIL: file is corrupt/unplayable after forced kill ($OUT)"
    exit 1
fi
