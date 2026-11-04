#!/usr/bin/env bash
# Hailo-10H (Seeed M.2 HAT) -- driver, firmware and device permissions.
#
# The Raspberry Pi OS equivalent is `apt install hailo-h10-all`, which, like the
# Hailo-8's `hailo-all`, isn't in the Ubuntu archive. So the PCIe driver is built
# from source via DKMS here too.
#
# Requires fetch-sources.sh to have been run first (as your normal user):
#   sudo bash setup.sh        (or: pkexec bash setup.sh)
#
# Coexists with the Hailo-8 setup in ../hailo8 rather than replacing it: the 5.x
# driver is a different module (hailo1x_pci, not hailo_pci) with a disjoint PCI
# ID table, a different firmware directory, and a different device class
# (hailo1x, not hailo_chardev). Both DKMS modules stay installed, and whichever
# accelerator is in the slot is the one that binds.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

HAILO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="5.5.0"
DRIVER_SRC="$HAILO_DIR/src/hailort-drivers"
FW_SRC="$HAILO_DIR/src/hailo10h_fw_$VERSION"
DKMS_NAME="hailo1x_pci"
DKMS_SRC="/usr/src/$DKMS_NAME-$VERSION"

say "Hailo-10H: installing build toolchain and kernel headers"
# libssl-dev is for hailo-ollama (oatpp-openssl), not the driver; installed here
# so that the user-side build scripts never need root.
apt_install build-essential cmake git dkms linux-headers-raspi libssl-dev

if [[ ! -d "$DRIVER_SRC" || ! -f "$FW_SRC/customer_certificate.bin" ]]; then
  warn "Sources or firmware not found under $HAILO_DIR/src"
  warn "Run first, as your normal user:  bash $HAILO_DIR/fetch-sources.sh"
  exit 1
fi

say "Hailo-10H: installing accelerator firmware"
# The driver requests these as hailo/hailo10h/<name>, in boot stages, and picks
# the device tree by SKU: u-boot-<sku>.dtb.signed, or u-boot-default.dtb.signed,
# which is a symlink -- hence -P, which copies the link rather than its target.
FW_DEST=/lib/firmware/hailo/hailo10h
rm -rf "$FW_DEST"
install -d "$FW_DEST"
cp -P --preserve=mode,timestamps "$FW_SRC"/* "$FW_DEST/"
chown -Rh root:root "$FW_DEST"
info "installed $(ls -1 "$FW_DEST" | wc -l) files -> $FW_DEST"

say "Hailo-10H: building and installing the PCIe driver via DKMS"
# 5.x has no `install_dkms` target -- the Hailo-8 branch's Makefile, and with it
# the ../../../../common/include path bug that ../hailo8/setup.sh works around,
# are gone. What it ships instead is linux/pcie/dkms.conf.in, which builds from
# the repository root, so the whole checkout goes to /usr/src.
if dkms status "$DKMS_NAME/$VERSION" | grep -q .; then
  info "removing the existing $DKMS_NAME/$VERSION registration first"
  dkms remove "$DKMS_NAME/$VERSION" --all
fi
rm -rf "$DKMS_SRC"
mkdir -p "$DKMS_SRC"
tar -C "$DRIVER_SRC" --exclude=.git -cf - . | tar -C "$DKMS_SRC" -xf -
sed "s/@PCIE_DRIVER_VERSION@/$VERSION/" "$DRIVER_SRC/linux/pcie/dkms.conf.in" > "$DKMS_SRC/dkms.conf"

dkms add "$DKMS_NAME/$VERSION"
# Kbuild builds with -Werror, so a new kernel's warning is a failed build, not a
# noisy one. DKMS keeps the compiler output when that happens.
if ! dkms build "$DKMS_NAME/$VERSION"; then
  warn "build failed -- see /var/lib/dkms/$DKMS_NAME/$VERSION/build/make.log"
  exit 1
fi
dkms install "$DKMS_NAME/$VERSION"

# The apt_install above can itself pull in a newer kernel (linux-headers-raspi
# drags linux-image-raspi along), and DKMS only builds modules for new kernels
# that are already registered when the kernel arrives. This one wasn't yet, so
# without this loop the next boot would come up with no 10H driver at all.
for kdir in /lib/modules/*/build; do
  kver="$(basename "$(dirname "$kdir")")"
  [[ "$kver" == "$(uname -r)" ]] && continue
  if dkms install "$DKMS_NAME/$VERSION" -k "$kver"; then
    info "also built for $kver"
  else
    warn "build for $kver failed -- see /var/lib/dkms/$DKMS_NAME/$VERSION/build/make.log"
  fi
done

say "Hailo-10H: device node permissions"
# Same policy as ../hailo8/setup.sh -- 0660, a logind uaccess ACL for the active
# seat, and the 'hailo' group for headless use -- but a rule of its own: the 5.x
# driver registers class "hailo1x" and names its nodes /dev/h1x-<n>, so the
# Hailo-8 rule's SUBSYSTEM=="hailo_chardev" never matches it.
getent group hailo >/dev/null || groupadd --system hailo
cat > /etc/udev/rules.d/52-hailo1x-udev.rules <<'EOT'
# Hailo-10H PCIe accelerator (driver hailo1x_pci, nodes /dev/h1x-<n>). Same policy
# as 51-hailo-udev.rules: 0660 + a logind uaccess ACL for the active seat, and the
# 'hailo' group for headless access.
SUBSYSTEM=="hailo1x", GROUP="hailo", MODE="0660", TAG+="uaccess"
EOT
add_user_to_group hailo
udevadm control --reload-rules

say "Hailo-10H: PCIe interrupt vectors"
# The Pi 5 routes the external PCIe slot's MSIs through the "MIP" by default,
# which has 8 vectors. Behind the Seeed HAT's ASM2806 switch those are all taken
# before the 10H asks: one per switch downstream port (4) and one per NVMe queue
# (4). Its pci_enable_msi() then fails with -ENOSPC, logged as
#   hailo1x 0001:03:00.0: Failed to enable MSI -28
# The Hailo-8 never hit this because it had the slot to itself.
#
# no-mip moves MSIs to the root complex's own target, which overlays/README
# recommends when "more than 8 interrupt vectors are required". It is a boot-time
# device tree change, so it only takes effect after a reboot.
CONFIG=/boot/firmware/config.txt
OVERLAY="dtoverlay=pciex1-compat-pi5,no-mip"
if grep -qxF "$OVERLAY" "$CONFIG"; then
  info "$OVERLAY already in $CONFIG"
else
  [[ -f "$CONFIG.bak-hailo10h" ]] || cp -p "$CONFIG" "$CONFIG.bak-hailo10h"
  cat >> "$CONFIG" <<EOT

# Hailo-10H + NVMe behind the Seeed M.2 HAT's PCIe switch need more than the
# MIP's 8 MSI vectors. Added by cyberdeck/hailo10h/setup.sh.
[all]
$OVERLAY
EOT
  info "added $OVERLAY to $CONFIG (backup: $CONFIG.bak-hailo10h)"
fi
# Whether it's live, rather than merely configured: with it active, nothing is
# routed through the MIP any more.
if grep -q "MIP-MSI" /proc/interrupts; then
  say "Hailo-10H: reboot needed"
  info "The driver is installed, but the interrupt change needs a reboot."
  info "After rebooting, check:  ls -l /dev/h1x-0"
  info "Then, as your normal user:  bash $HAILO_DIR/build-hailort.sh"
  # ../setup.sh sources each part rather than running it, so `exit` here would
  # end the whole orchestrator run; `return` only ends this part.
  return 0 2>/dev/null || exit 0
fi

say "Hailo-10H: loading the driver"
# The probe pushes ~110 MB of firmware in stages before it creates the node --
# versus the Hailo-8's 150 KB -- so give it a moment rather than checking at once.
depmod -a
modprobe -r "$DKMS_NAME" 2>/dev/null || true
modprobe "$DKMS_NAME" || warn "modprobe failed -- check: journalctl -k | grep -i hailo"
udevadm trigger --subsystem-match=hailo1x || true
for _ in $(seq 1 30); do
  [[ -e /dev/h1x-0 ]] && break
  sleep 1
done

say "Hailo-10H: done"
if [[ -e /dev/h1x-0 ]]; then
  info "device node present: $(ls -l /dev/h1x-0)"
else
  warn "/dev/h1x-0 did not appear -- check: journalctl -k | grep -i hailo"
fi
info "Next, as your normal user:  bash $HAILO_DIR/build-hailort.sh"
