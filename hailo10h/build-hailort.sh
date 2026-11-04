#!/usr/bin/env bash
# Build HailoRT 5.5 (libhailort + hailortcli) from source.
#
# Run as your normal user, after setup.sh:
#   bash build-hailort.sh
#
# Same recipe as ../hailo8/build-hailort.sh, against the v5.5.0 sources. libhailort
# 5.x carries the GenAI (LLM) API that hailo-ollama is built on; no extra option
# is needed for it.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SRC="src/hailort"
JOBS="${JOBS:-$(( $(nproc) - 1 ))}"

if [[ ! -d "$SRC" ]]; then
  echo "HailoRT sources not found at $SRC -- run: bash fetch-sources.sh" >&2
  exit 1
fi

# -DCMAKE_POLICY_VERSION_MINIMUM=3.5: Ubuntu 26.04's CMake 4 refuses
# cmake_minimum_required(VERSION <3.5), which the dependencies HailoRT fetches at
# configure time still declare. See ../hailo8/build-hailort.sh for the full story.
echo "Configuring (CMake $(cmake --version | head -1 | awk '{print $3}'))"
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -Wno-dev

echo "Building with $JOBS jobs (this takes a while on a Pi 5)"
cmake --build "$SRC/build" --config Release -j "$JOBS"

echo
echo "Built:"
find "$SRC/build" \( -name hailortcli -o -name "libhailort.so*" \) -printf "  %p\n" 2>/dev/null

cat <<EOT

Next, install system-wide (replaces HailoRT 4.24 in /usr/local):
  sudo bash install-hailort.sh
EOT
