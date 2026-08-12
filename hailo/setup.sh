#!/usr/bin/env bash
# Hailo-8 AI HAT+ (26 TOPS) — driver, firmware and device permissions.
#
# On Raspberry Pi OS this is `apt install hailo-all`. That package doesn't exist
# in the Ubuntu archive, and the Raspberry Pi apt repo must not be added to an
# Ubuntu system, so we build the PCIe driver from source via DKMS instead.
#
# Requires hailo/fetch-sources.sh to have been run first (as your normal user).
#
# Good news, contrary to expectations: the hailo8 branch builds cleanly against
# the 7.0.0-raspi kernel with no patching. The `del_timer_sync` -> `timer_delete_sync`
# rename in kernel 6.15 that broke Hailo's master branch (and needed their
# v5.3.0-hotfix-kernel-above-6.15 tag) is already handled here.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

HAILO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_SRC="$HAILO_DIR/src/hailort-drivers"

say "Hailo: installing build toolchain and kernel headers"
apt_install build-essential cmake git dkms linux-headers-raspi

if [[ ! -d "$DRIVER_SRC" ]]; then
  warn "Driver sources not found at $DRIVER_SRC"
  warn "Run first, as your normal user:  bash $HAILO_DIR/fetch-sources.sh"
  exit 1
fi

say "Hailo: installing accelerator firmware"
# The driver calls request_firmware_direct("hailo/hailo8_fw.bin"), so the
# versioned download has to be installed under that exact name. Only this file
# is mandatory; hailo8_board_cfg.bin and hailo8_fw_cfg.bin are optional.
firmware_src="$(ls -1 "$DRIVER_SRC"/hailo8_fw.*.bin 2>/dev/null | head -1 || true)"
if [[ -z "$firmware_src" ]]; then
  warn "No hailo8_fw.*.bin in $DRIVER_SRC — re-run fetch-sources.sh"
  exit 1
fi
install -d /lib/firmware/hailo
install -m 0644 "$firmware_src" /lib/firmware/hailo/hailo8_fw.bin
info "installed $(basename "$firmware_src") -> /lib/firmware/hailo/hailo8_fw.bin"

say "Hailo: building and installing the PCIe driver via DKMS"
# DKMS so the module is rebuilt automatically on kernel upgrades — this machine
# already has five raspi kernels installed, so a plain `make install` would stop
# working at the next boot into a different one.
#
# Upstream bug, not an Ubuntu one: both Makefile and Kbuild refer to
#   COMMON_INCLUDE_DIRECTORY = ../../../../common/include
# which resolves *outside* the standalone hailort-drivers checkout. It only
# exists in Hailo's internal monorepo, where the driver sits at hailort/drivers/.
# Compiling is unaffected (gcc silently ignores a missing -I path, and the header
# it needs is found via COMMON_SRC_DIRECTORY), but `make install_dkms` does a
# literal `cp -r` of that path and dies with "cannot stat".
#
# The DKMS tree really does expect .../common/include, because Kbuild re-resolves
# the same relative path once the sources are laid out under KBUILD_PATH. So
# stage a directory of that name and point the copy at it, rather than patching
# upstream files we'd have to re-apply on every update.
say "Hailo: staging the include directory upstream expects"
STAGE="$DRIVER_SRC/../dkms-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/include"
cp "$DRIVER_SRC"/common/*.h "$STAGE/include/"
info "staged $(ls -1 "$STAGE/include" | wc -l) headers in $STAGE/include"

# Drop objects from any earlier local build so they don't get copied into
# /usr/src along with the sources.
make -C "$DRIVER_SRC/linux/pcie" clean >/dev/null 2>&1 || true

make -C "$DRIVER_SRC/linux/pcie" \
  COMMON_INCLUDE_DIRECTORY="$STAGE/include" \
  install_dkms

say "Hailo: device node permissions"
# Hailo's own rule (linux/pcie/51-hailo-udev.rules) is MODE="0666" -- the
# accelerator readable and writable by every account on the machine, including
# service users. We keep the same access for the desktop user via the same
# mechanism Ubuntu uses for I2C and the camera: a logind 'uaccess' ACL for the
# active local seat, plus a 'hailo' group for headless/SSH use.
getent group hailo >/dev/null || groupadd --system hailo
cat > /etc/udev/rules.d/51-hailo-udev.rules <<'EOF'
# Hailo PCIe accelerator. Deliberately tighter than Hailo's shipped MODE="0666":
# 0660 + a logind uaccess ACL for the active seat, and the 'hailo' group for
# headless access.
SUBSYSTEM=="hailo_chardev", GROUP="hailo", MODE="0660", TAG+="uaccess"
EOF
add_user_to_group hailo
udevadm control --reload-rules

say "Hailo: loading the driver"
depmod -a
modprobe hailo_pci || warn "modprobe failed — check 'dmesg | grep -i hailo'"
udevadm trigger --subsystem-match=hailo_chardev || true

say "Hailo: done"
if [[ -e /dev/hailo0 ]]; then
  info "device node present: $(ls -l /dev/hailo0)"
else
  warn "/dev/hailo0 did not appear — check 'dmesg | grep -i hailo'"
fi
info "Verify with:  hailortcli fw-control identify   (needs HailoRT — see hailo/README.md)"
