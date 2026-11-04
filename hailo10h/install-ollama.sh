#!/usr/bin/env bash
# Install Hailo-Ollama system-wide: the binary to /usr/local/bin and the model
# manifests (the catalogue of what can be pulled) to /usr/local/share.
#
#   sudo bash install-ollama.sh
#
# Run build-ollama.sh first, as your normal user. Models themselves are not
# installed here -- they're pulled per user, into ~/.local/share/hailo-ollama.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

HAILO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HAILO_DIR/src/hailo_model_zoo_genai/build"

if [[ ! -f "$BUILD/CMakeCache.txt" ]]; then
  warn "No build found at $BUILD"
  warn "Run first, as your normal user:  bash $HAILO_DIR/build-ollama.sh"
  exit 1
fi

say "Hailo-Ollama: installing"
cmake --install "$BUILD"

say "Hailo-Ollama: done"
info "hailo-ollama: $(command -v hailo-ollama || echo 'not on PATH')"
info "Start it, as your normal user:  bash $HAILO_DIR/run-ollama.sh"
