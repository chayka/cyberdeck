#!/usr/bin/env bash
# Install the HailoRT build system-wide (libhailort + hailortcli).
#
#   sudo bash install-hailort.sh
#
# Run build-hailort.sh first, as your normal user.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

HAILO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HAILO_DIR/src/hailort/build"

if [[ ! -f "$BUILD/hailort/hailortcli/hailortcli" ]]; then
  warn "No build found at $BUILD"
  warn "Run first, as your normal user:  bash $HAILO_DIR/build-hailort.sh"
  exit 1
fi

say "HailoRT: installing"
cmake --install "$BUILD"

say "HailoRT: refreshing the linker cache"
# Installs into /usr/local/lib, which is on the default search path but needs
# ldconfig before hailortcli can find libhailort.so.
ldconfig

say "HailoRT: done"
info "hailortcli: $(command -v hailortcli || echo 'not on PATH')"
info "Verify with:  hailortcli fw-control identify"
