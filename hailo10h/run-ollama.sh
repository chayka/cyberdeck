#!/usr/bin/env bash
# Start Hailo-Ollama on localhost.
#
#   bash run-ollama.sh                      # 127.0.0.1:8000
#   OLLAMA_HOST=0.0.0.0:8000 bash run-ollama.sh   # deliberately on the network
#
# Upstream binds 0.0.0.0:8000 by default -- every network the deck joins could
# drive the accelerator, with no authentication. A deck on café WiFi is the
# wrong place for that default, so this wrapper narrows it to loopback unless
# OLLAMA_HOST says otherwise.

set -euo pipefail

export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:8000}"

command -v hailo-ollama >/dev/null || {
  echo "hailo-ollama not installed -- see install-ollama.sh" >&2
  exit 1
}
[[ -e /dev/h1x-0 ]] || {
  echo "/dev/h1x-0 missing -- the driver isn't bound; see setup.sh" >&2
  exit 1
}

# HailoRT writes hailort.log into the working directory; keep it out of whatever
# directory this was started from.
mkdir -p "$HOME/.hailo/hailort"
cd "$HOME/.hailo/hailort"

echo "Hailo-Ollama on http://$OLLAMA_HOST"
exec hailo-ollama
