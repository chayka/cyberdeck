#!/usr/bin/env bash
# Hailo-8 AI HAT (26 TOPS) — system setup.
#
# Status: build toolchain only. The driver build is not wired up yet.
#
# On Raspberry Pi OS this is one `apt install hailo-all`. That package does not
# exist in the Ubuntu archive and the Raspberry Pi apt repo must not be added to
# an Ubuntu system, so the PCIe driver (hailo_pci, via DKMS), its matching
# firmware, and the HailoRT userspace library all have to be built from source
# against kernel 7.0.0-raspi. That work is tracked separately -- this script only
# installs what the build will need.
#
# Current state on this machine: the Hailo-8 enumerates on PCIe at 0001:01:00.0
# but there is no /dev/hailo0, i.e. no driver bound.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

say "Hailo: installing build toolchain and kernel headers"
apt_install build-essential cmake git dkms linux-headers-raspi

say "Hailo: toolchain ready"
warn "Driver and HailoRT are not installed yet -- see hailo/README.md"
info "After install, verify with:  hailortcli fw-control identify"
