#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
native_bin_dir=$(swift build -c release --show-bin-path)
if [ "${NULL_TEST_GPU:-0}" = "1" ]; then
    "$native_bin_dir/GCodeChecks" Sources/GCodePlayer/Shaders/Preview.metal
else
    "$native_bin_dir/GCodeChecks"
fi
