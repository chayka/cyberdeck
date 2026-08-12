#!/usr/bin/env bash
# Fetch Waveshare's original UPS HAT (E) demo code for reference.
#
# Kept out of git (see .gitignore): it's Waveshare's code, not ours, and
# redistributing it here would muddy the licensing of this repo. Our port lives
# in ups_hat_e.py and indicator.py and does not depend on anything downloaded here.
#
#   bash fetch-vendor.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

WIKI="https://www.waveshare.com/wiki/UPS_HAT_(E)"
ARCHIVE="https://files.waveshare.com/wiki/UPS-HAT-E/UPS_HAT_E.zip"

mkdir -p vendor
cd vendor

echo "Downloading vendor demo from $ARCHIVE"
curl -fsSL -A "Mozilla/5.0" -o UPS_HAT_E.zip "$ARCHIVE"
unzip -o -q UPS_HAT_E.zip

echo "Extracted to $(pwd)/UPS_HAT_E"
echo "Wiki reference: $WIKI"
