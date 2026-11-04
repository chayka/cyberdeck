#!/usr/bin/env bash
# Build HailoRT's Python bindings and make them importable from hailo8/.venv.
#
# Run as your normal user (no sudo):
#   bash install-pyhailort.sh
#
# Requires: build-hailort.sh + install-hailort.sh done, and make-venvs.sh run.
#
# Two things here are contrary to expectation and worth knowing:
#
# 1. HailoRT v4.24 pins pybind11 2.13.6, which predates Python 3.14 — so this
#    looked likely to fail on Ubuntu 26.04. It builds and imports cleanly.
#
# 2. We deliberately DO NOT install the package's requirements.txt. Its pins are
#    years stale (netifaces==0.10.9, future==0.18.2, importlib-metadata==5.1.0)
#    and several cannot build on Python 3.14. Nothing we use needs them; numpy
#    comes from the distro and is visible via --system-site-packages.
#
# Rather than `pip install .` (whose setup.py re-runs the whole cmake build), we
# drop the compiled module next to its pure-Python package and add a .pth file
# to the venv. Reversible: delete the .pth to undo.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

HAILO_DIR="$PWD"
PLATFORM_DIR="$HAILO_DIR/src/hailort/hailort/libhailort/bindings/python/platform"
BINDINGS_SRC="$HAILO_DIR/src/hailort/hailort/libhailort/bindings/python/src"
BUILD_DIR="$HAILO_DIR/src/hailort/build-pyhailort"
VENV="$HAILO_DIR/.venv"

PY_VERSION="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

[[ -d "$VENV" ]] || { echo "No venv at $VENV — run: bash ../make-venvs.sh" >&2; exit 1; }
[[ -d "$PLATFORM_DIR" ]] || { echo "Sources missing — run: bash fetch-sources.sh" >&2; exit 1; }

echo "Building _pyhailort for Python $PY_VERSION"
cmake -S "$BINDINGS_SRC" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DPYBIND11_PYTHON_VERSION="$PY_VERSION" \
  -Wno-dev >/dev/null
cmake --build "$BUILD_DIR" -j "$(( $(nproc) - 1 ))"

module="$(find "$BUILD_DIR" -name "_pyhailort*.so" | head -1)"
[[ -n "$module" ]] || { echo "Build produced no module" >&2; exit 1; }
cp "$module" "$PLATFORM_DIR/hailo_platform/pyhailort/"
echo "installed $(basename "$module")"

site="$VENV/lib/python$PY_VERSION/site-packages"
echo "$PLATFORM_DIR" > "$site/hailo_platform.pth"
echo "added $site/hailo_platform.pth"

"$VENV/bin/python" -c "
from hailo_platform import VDevice, HEF
print('hailo_platform imports OK')"
