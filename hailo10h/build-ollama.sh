#!/usr/bin/env bash
# Build Hailo-Ollama, the Ollama-compatible LLM server for the Hailo-10H.
#
# Run as your normal user, after install-hailort.sh:
#   bash build-ollama.sh
#
# It links against the installed libhailort (find_package(HailoRT 5)), so the
# 4.24 runtime must already have been replaced, and OpenSSL's headers, which
# setup.sh installs.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SRC="src/hailo_model_zoo_genai"
JOBS="${JOBS:-$(( $(nproc) - 1 ))}"

if [[ ! -d "$SRC" ]]; then
  echo "Hailo-Ollama sources not found at $SRC -- run: bash fetch-sources.sh" >&2
  exit 1
fi

# Its own minimum is 3.20, but the policy flag is kept for the same reason as in
# build-hailort.sh: it fetches oatpp, eventpp, json and minja at configure time.
echo "Configuring"
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -Wno-dev

echo "Building with $JOBS jobs"
cmake --build "$SRC/build" --config Release -j "$JOBS"

echo
echo "Built:"
find "$SRC/build" -type f -name hailo-ollama -printf "  %p\n"

cat <<EOT

Next, install system-wide:
  sudo bash install-ollama.sh
EOT
