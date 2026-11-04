#!/usr/bin/env bash
# Fetch the Hailo-10H driver, runtime, Hailo-Ollama sources and firmware.
#
# Run as your normal user (no sudo) -- nothing here touches the system:
#   bash fetch-sources.sh
#
# Everything lands in hailo10h/src/, which is gitignored, like hailo8/src/ for the
# Hailo-8.
#
# The Hailo-10H is on `master`/v5.x everywhere, the mirror image of the Hailo-8
# branch trap in hailo8/fetch-sources.sh. All four pieces are pinned to one version
# because they must match: driver, firmware, libhailort and hailo-ollama
# (whose CMakeLists asks for `find_package(HailoRT 5)`).
#
#   lspci -nn | grep -i hailo
#     [1e60:45c4] -> Hailo-10H  -> this directory
#     [1e60:2864] -> Hailo-8    -> ../hailo8

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="5.5.0"
TAG="v$VERSION"

mkdir -p src
cd src

# Shallow-clone a repo at TAG, or move an existing checkout to it.
fetch() {
  local name="$1" repo="https://github.com/hailo-ai/$1.git"
  if [[ -d "$name/.git" ]]; then
    echo "Updating $name to $TAG"
    git -C "$name" fetch -q --depth 1 origin tag "$TAG"
    git -C "$name" checkout -q "$TAG"
  else
    echo "Cloning $name ($TAG)"
    git -c advice.detachedHead=false clone -q --branch "$TAG" --depth 1 "$repo"
  fi
  echo "  at: $(git -C "$name" log --oneline -1)"
}

fetch hailort-drivers
fetch hailort
fetch hailo_model_zoo_genai

# Firmware from Hailo's public S3 bucket -- no login, same as the Hailo-8's. We
# fetch it ourselves rather than run upstream's download_firmware_hailo10h.sh,
# which pins its own version: this way the one VERSION above governs everything.
#
# Unlike the Hailo-8's single hailo8_fw.bin, the 10H boots a small Linux of its
# own: u-boot, a kernel (fitImage), a root filesystem (image-fs, ~100 MB) and one
# signed device tree per board SKU, with u-boot-default.dtb.signed a symlink to
# the one the driver asks for. The tarball is flat, so it unpacks straight into
# the directory setup.sh installs from.
#
# Proprietary, under "Hailo10H FW License" in the driver checkout: binary-only
# redistribution, and it forbids publishing benchmark results.
FW_DIR="hailo10h_fw_$VERSION"
FW_URL="https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo10H/$VERSION/FW/hailo10h_fw.tar.gz"
if [[ -f "$FW_DIR/customer_certificate.bin" ]]; then
  echo "Firmware $VERSION already present"
else
  echo "Downloading firmware $VERSION"
  rm -rf "$FW_DIR.partial"
  mkdir -p "$FW_DIR.partial"
  curl -fSL --progress-bar "$FW_URL" | tar -xz -C "$FW_DIR.partial"
  mv "$FW_DIR.partial" "$FW_DIR"
fi
echo "  $(ls -1 "$FW_DIR" | wc -l) files in src/$FW_DIR"

cat <<'EOT'

Sources ready. Next:
  sudo bash setup.sh              # driver via DKMS, firmware, udev, modprobe
  bash build-hailort.sh           # libhailort 5.5 + hailortcli
EOT
