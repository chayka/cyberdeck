#!/usr/bin/env bash
# Waveshare UPS HAT (E) — system setup.
#
# The HAT is read over I2C bus 1. Two udev rules both match /dev/i2c-* here, and
# the interaction is worth understanding before debugging any permission error:
#
#   60-gpio.rules       (ubuntu-raspi-settings)  GROUP="dialout" TAG+="uaccess"
#   60-i2c-tools.rules  (i2c-tools)              GROUP="i2c"
#
# 60-i2c-tools sorts later, so its GROUP wins and the node ends up root:i2c --
# while the 'uaccess' tag from the earlier rule still applies. uaccess makes
# systemd-logind grant an ACL to whoever holds the active local seat, which is
# what actually permits access in a desktop session:
#
#   $ getfacl /dev/i2c-1  ->  user:<you>:rw-
#
# So on a graphical login this works with no group membership at all. Over SSH
# there is no seat, no ACL, and group membership is the only route -- and it must
# be 'i2c', not 'dialout', because i2c-tools won the GROUP assignment. We add
# both so the HAT is readable locally and headlessly.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

say "UPS HAT (E): installing I2C tooling"
# smbus2, not the old python3-smbus the vendor demo imports: that binding isn't
# packaged for Python 3.14 on Ubuntu 26.04.
apt_install i2c-tools python3-smbus2

say "UPS HAT (E): installing top-bar indicator dependencies"
# GNOME 50/Wayland has no XEmbed tray, so the PyQt5 QSystemTrayIcon approach in
# the vendor demo cannot work. AyatanaAppIndicator3 emits StatusNotifierItem,
# which the already-enabled ubuntu-appindicators extension picks up.
apt_install python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1
# Optional: desktop notifications when the pack goes critical.
apt_install gir1.2-notify-0.7 || warn "libnotify GIR unavailable; indicator will log warnings to the journal instead"

say "UPS HAT (E): granting I2C device access"
# Belt and braces; see the note at the top of this file for which one applies when.
add_user_to_group i2c
add_user_to_group dialout

say "UPS HAT (E): done"
info "Verify the HAT is on the bus:  i2cdetect -y 1     (expect 0x2d)"
info "Read it once:                  python3 ups/ups_hat_e.py"
info "Install the top-bar indicator: bash ups/install-indicator.sh   (no sudo)"
info "Group changes need a new login session (or 'newgrp dialout' in this shell)."
