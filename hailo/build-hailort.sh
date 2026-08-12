#!/usr/bin/env bash
# Build HailoRT (libhailort + hailortcli) from source.
#
# Run as your normal user (building as root is a bad habit and unnecessary):
#   bash build-hailort.sh
#
# Then install with the root step it prints at the end.
#
# Raspberry Pi OS gets this as part of `apt install hailo-all`. On Ubuntu it's a
# source build, and it must be version-matched to the driver and firmware --
# all three are v4.24.0 on the `hailo8` branch.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SRC="src/hailort"
JOBS="${JOBS:-$(( $(nproc) - 1 ))}"

if [[ ! -d "$SRC" ]]; then
  echo "HailoRT sources not found at $SRC — run: bash fetch-sources.sh" >&2
  exit 1
fi

# -DCMAKE_POLICY_VERSION_MINIMUM=3.5 is required on Ubuntu 26.04 and is NOT in
# any Hailo documentation, because it's an Ubuntu-only problem:
#
#   Ubuntu 26.04 ships CMake 4.2, which REMOVED support for
#   cmake_minimum_required(VERSION <3.5). Raspberry Pi OS Trixie ships CMake 3.x,
#   where this is merely deprecated.
#
# HailoRT's own CMakeLists and its vendored deps (cli11, json, dotwriter) still
# declare pre-3.5 minimums, so configuration fails outright without this flag:
#
#   CMake Error at hailort/external/cli11-src/CMakeLists.txt:1:
#     Compatibility with CMake < 3.5 has been removed from CMake.
#
# The flag makes CMake 4 treat those as 3.5 rather than erroring. It's the escape
# hatch CMake itself suggests, and preferable to patching dozens of vendored files.
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

cat <<EOF

Next, install system-wide:
  sudo cmake --install $SRC/build
  sudo ldconfig

Then verify against the accelerator:
  hailortcli fw-control identify
EOF
