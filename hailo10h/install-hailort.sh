#!/usr/bin/env bash
# Install the HailoRT 5.5 build system-wide, replacing 4.24 in /usr/local.
#
#   sudo bash install-hailort.sh
#
# Run build-hailort.sh first, as your normal user.
#
# Only one HailoRT can be the one in /usr/local, and with the Hailo-10H in the
# slot it's 5.5. Going back to the Hailo-8 means re-running
# ../hailo8/install-hailort.sh, which puts 4.24 back the same way.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

HAILO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HAILO_DIR/src/hailort/build"

if [[ ! -f "$BUILD/hailort/hailortcli/hailortcli" ]]; then
  warn "No build found at $BUILD"
  warn "Run first, as your normal user:  bash $HAILO_DIR/build-hailort.sh"
  exit 1
fi

say "HailoRT 5.5: clearing the 4.24 headers and CMake package"
# `cmake --install` overwrites files but never deletes them, so headers 5.5
# dropped would linger in include/hailo, and a stale CMake package could satisfy
# a find_package(HailoRT) meant for the other version. libhailort.so.4.24.0 is
# left alone: nothing resolves to it once libhailort.so points at 5.5, and
# keeping it means ../hailo8/.venv's bindings still load if 4.24 comes back.
rm -rf /usr/local/include/hailo /usr/local/lib/cmake/HailoRT

say "HailoRT 5.5: installing"
cmake --install "$BUILD"

say "HailoRT 5.5: refreshing the linker cache"
ldconfig

say "HailoRT 5.5: done"
info "hailortcli: $(command -v hailortcli || echo 'not on PATH')"
info "libhailort.so -> $(readlink /usr/local/lib/libhailort.so || echo missing)"
info "Verify with:  hailortcli fw-control identify"
info "Then, as your normal user:  bash $HAILO_DIR/build-ollama.sh"
