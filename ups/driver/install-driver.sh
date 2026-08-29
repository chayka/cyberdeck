#!/usr/bin/env bash
# Install the UPS HAT (E) power_supply driver.
#
#   sudo bash install-driver.sh              install and start
#   sudo bash install-driver.sh --uninstall  remove it again
#
# After this the pack is a real battery: /sys/class/power_supply/BAT0, visible to
# UPower, GNOME's power menu and anything else that asks the kernel "am I on
# battery?". The custom top-bar indicator becomes redundant — see the note the
# script prints at the end.

source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib.sh"
require_root

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="ups-hat-e"
VERSION="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$HERE/dkms.conf")"
SRC="/usr/src/$NAME-$VERSION"
RULE="/etc/udev/rules.d/99-$NAME.rules"

# Removing the I2C client before unloading matters: the client is created by the
# udev rule, not by the module, so it outlives a plain `rmmod` and the driver
# would rebind to a stale device on the next modprobe.
remove_i2c_client() {
  local dev id adapter
  # Match on the device rather than on the driver's bound children: a client
  # whose probe failed, or one created while the module was absent, still holds
  # the address and still has to be released.
  for dev in /sys/bus/i2c/devices/*-002d; do
    [[ -e "$dev/name" ]] || continue
    [[ "$(cat "$dev/name")" == "$NAME" ]] || continue
    id="$(basename "$dev")"
    adapter="/sys/bus/i2c/devices/i2c-${id%%-*}"
    echo 0x2d > "$adapter/delete_device" 2>/dev/null || true
    info "released $id"
  done
}

if [[ "${1:-}" == "--uninstall" ]]; then
  say "UPS HAT (E) driver: removing"
  rm -f "$RULE"
  udevadm control --reload-rules
  remove_i2c_client
  modprobe -r "${NAME//-/_}" 2>/dev/null || true
  if dkms status -m "$NAME" -v "$VERSION" 2>/dev/null | grep -q .; then
    dkms remove -m "$NAME" -v "$VERSION" --all
  fi
  rm -rf "$SRC"
  say "UPS HAT (E) driver: removed"
  info "The pack is no longer a system battery. 0x2d is released, so the indicator"
  info "and 'python3 ups_hat_e.py' fall back to reading the MCU directly — restart"
  info "the indicator so it reopens the bus:"
  info "  systemctl --user restart cyberdeck-ups.service"
  exit 0
fi

say "UPS HAT (E) driver: installing build dependencies"
# linux-headers-raspi is the metapackage that tracks the running flavour, so DKMS
# still has headers to build against after the next kernel upgrade.
apt_install dkms build-essential linux-headers-raspi

say "UPS HAT (E) driver: staging source at $SRC"
# A previous DKMS registration has to go before the source is replaced, or dkms
# ends up with a build tree that no longer matches what it recorded.
if dkms status -m "$NAME" -v "$VERSION" 2>/dev/null | grep -q .; then
  info "removing the previously installed version"
  dkms remove -m "$NAME" -v "$VERSION" --all || true
fi
rm -rf "$SRC"
install -d "$SRC"
install -m644 "$HERE/ups-hat-e.c" "$HERE/Makefile" "$HERE/dkms.conf" "$SRC/"

say "UPS HAT (E) driver: building via DKMS"
dkms add -m "$NAME" -v "$VERSION"
dkms build -m "$NAME" -v "$VERSION"
dkms install -m "$NAME" -v "$VERSION"

say "UPS HAT (E) driver: installing the udev rule"
install -m644 "$HERE/99-$NAME.rules" "$RULE"
udevadm control --reload-rules

say "UPS HAT (E) driver: binding to the HAT"
# Re-trigger the header I2C adapter so the rule fires now rather than at the next
# boot. `udevadm trigger` replays an 'add' event for devices that already exist.
remove_i2c_client
modprobe -r "${NAME//-/_}" 2>/dev/null || true
udevadm trigger --subsystem-match=i2c --action=add
udevadm settle

for _ in $(seq 20); do
  [[ -e /sys/class/power_supply/BAT0 ]] && break
  sleep 0.25
done

if [[ ! -e /sys/class/power_supply/BAT0 ]]; then
  warn "BAT0 did not appear. Check:  journalctl -k -b | grep ups-hat-e"
  warn "and that the HAT answers:    i2cdetect -y 1     (expect 0x2d)"
  exit 1
fi

say "UPS HAT (E) driver: done"
info "battery:  $(cat /sys/class/power_supply/BAT0/capacity)%  $(cat /sys/class/power_supply/BAT0/status)"
info "input:    AC0 online=$(cat /sys/class/power_supply/AC0/online)"
info
info "Verify the desktop can see it:   upower -i /org/freedesktop/UPower/devices/battery_BAT0"
info "Board-specific detail:           cat /sys/class/power_supply/BAT0/cell_voltages"
info
# pgrep, not `systemctl --user`: querying another user's systemd instance from
# root needs its session bus and does not reliably work from a sudo shell.
if pgrep -u "$TARGET_USER" -f 'indicator\.py' >/dev/null 2>&1; then
  warn "The top-bar indicator is running and is now reading a dead bus: this driver"
  warn "owns 0x2d, so its direct I2C reads fail with EBUSY and it silently shows '--'."
  warn "It reads through the driver once restarted:"
  warn "  systemctl --user restart cyberdeck-ups.service"
  warn "Or retire it — GNOME draws the battery itself now:"
  warn "  systemctl --user disable --now cyberdeck-ups.service"
else
  info "GNOME draws the battery itself now, so the top-bar indicator is not needed."
  info "For the detail GNOME has nowhere to show — per-cell voltages, charge stage:"
  info "  python3 ups/ups_hat_e.py --watch"
fi
