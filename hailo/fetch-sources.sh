#!/usr/bin/env bash
# Fetch the Hailo PCIe driver sources and accelerator firmware.
#
# Run as your normal user (no sudo) -- nothing here touches the system:
#   bash fetch-sources.sh
#
# Everything lands in hailo/src/, which is gitignored: it's Hailo's GPL-2.0 source
# and their firmware blob, pinned by branch rather than vendored into this repo.
#
# THE IMPORTANT PART: the branch. hailort-drivers' `master` supports only the
# Hailo-10 and Hailo-15 families -- its own README says so, quietly, in one line.
# The AI HAT+ is a **Hailo-8**, which lives on the `hailo8` branch. Building the
# obvious-looking `master` or a v5.x tag produces a driver that compiles fine and
# then never binds to the device.
#
# Check which chip you have before trusting this:
#   lspci -nn | grep -i hailo
#     [1e60:2864] -> Hailo-8   (AI HAT+)      -> hailo8 branch, this script
#     Hailo-10H   -> AI HAT+ 2                -> master branch, different firmware

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

DRIVER_REPO="https://github.com/hailo-ai/hailort-drivers.git"
DRIVER_BRANCH="hailo8"

mkdir -p src
cd src

if [[ -d hailort-drivers/.git ]]; then
  echo "Updating existing hailort-drivers checkout"
  git -C hailort-drivers fetch --depth 1 origin "$DRIVER_BRANCH"
  git -C hailort-drivers checkout -q FETCH_HEAD
else
  echo "Cloning $DRIVER_REPO ($DRIVER_BRANCH)"
  git clone --branch "$DRIVER_BRANCH" --depth 1 "$DRIVER_REPO"
fi

cd hailort-drivers
echo "Driver at: $(git log --oneline -1)"
cd ..

# HailoRT userspace (libhailort + hailortcli). Same branch rule as the driver,
# and the versions must match: driver v4.24.0 <-> runtime v4.24.0 <-> firmware
# v4.24.0. Built by build-hailort.sh, not here.
RUNTIME_REPO="https://github.com/hailo-ai/hailort.git"
if [[ -d hailort/.git ]]; then
  echo "Updating existing hailort checkout"
  git -C hailort fetch --depth 1 origin "$DRIVER_BRANCH"
  git -C hailort checkout -q FETCH_HEAD
else
  echo "Cloning $RUNTIME_REPO ($DRIVER_BRANCH)"
  git clone --branch "$DRIVER_BRANCH" --depth 1 "$RUNTIME_REPO"
fi
echo "Runtime at: $(git -C hailort log --oneline -1)"

cd hailort-drivers

# Pulls hailo8_fw.<version>.bin from Hailo's public S3 bucket. No registration
# and no login required, unlike most of their developer-zone downloads. The
# firmware version is pinned inside the script and must match the driver.
echo "Downloading matching firmware"
bash download_firmware.sh

ls -l hailo8_fw.*.bin
echo
echo "Sources ready. Next: sudo bash ../setup.sh   (or: sudo bash ../../setup.sh hailo)"
