# Cyberdeck

Peripheral support for a custom Raspberry Pi 5 cyberdeck running **Ubuntu**, not
Raspberry Pi OS.

Nearly every driver, demo, and HAT vendor script for the Pi assumes Raspberry Pi
OS. Most of them fail on Ubuntu for reasons that have nothing to do with the
hardware — a group that doesn't exist, a display server that's been replaced, an
apt repo that isn't there. This repo is the corrected versions, plus notes on
*why* each change was needed.

## Hardware

| Part | Notes |
| --- | --- |
| Raspberry Pi 5 Model B Rev 1.1 | BCM2712, aarch64 |
| Hailo AI HAT, 26 TOPS | Hailo-8 on PCIe |
| Waveshare UPS HAT (E) | 4-cell, read over I2C at `0x2d` |
| Camera Module 3 Wide NoIR | `imx708` + `dw9807_vcm` autofocus |
| M.2 SSD | USB adapter (PCIe slot is taken by the AI HAT) |

Tested on Ubuntu 26.04 LTS, kernel `7.0.0-1016-raspi`, GNOME Shell 50.1 on
Wayland, Python 3.14.

## Layout

Each peripheral is self-contained, with its own `setup.sh`:

```
common/lib.sh      shared shell helpers
setup.sh           orchestrator — runs all parts, or the ones you name
ups/               Waveshare UPS HAT (E): kernel driver, reader, indicator
ups/driver/        power_supply kernel module — makes the pack a real battery
camera/            Camera Module 3: libcamera / rpicam-apps / Picamera2
hailo/             Hailo-8 AI HAT: PCIe driver + HailoRT
```

## Install

```bash
sudo bash setup.sh              # everything
sudo bash setup.sh ups camera   # or just some parts
```

All parts are idempotent. Group membership changes need a fresh login session.

Then make the pack a real system battery — GNOME power menu, low-battery
warnings, automatic shutdown before the cells are damaged:

```bash
sudo bash ups/driver/install-driver.sh
```

That supersedes the standalone top-bar indicator
(`ups/install-indicator.sh`), which is kept only as a fallback for running
without the kernel driver. Per-cell voltages and charge stage cannot be attached
to GNOME's own battery menu — it is built from UPower's schema, and UPower has
no mechanism for vendor-specific properties — but they are one command away:

```bash
python3 ups/ups_hat_e.py --watch
```

Order matters if you already had the indicator installed: the driver claims
`0x2d`, so its direct I2C reads start returning `EBUSY` and it silently renders
`--` rather than failing. Restart it and it reads through the driver instead.

## Verify

```bash
i2cdetect -y 1                  # UPS HAT should appear at 0x2d
python3 ups/ups_hat_e.py        # one-shot battery reading
upower -i /org/freedesktop/UPower/devices/battery_BAT0   # the desktop's view
rpicam-hello --list-cameras     # Camera Module 3
hailortcli fw-control identify  # Hailo-8 (not working yet)
```

## Raspberry Pi OS → Ubuntu, the differences that actually bite

These are the ones that cost real time on this build:

- **I2C permissions are not a group problem — until they are.** Two udev rules
  both match `/dev/i2c-*`: `60-gpio.rules` (from `ubuntu-raspi-settings`) sets
  `GROUP="dialout" TAG+="uaccess"`, and `60-i2c-tools.rules` (from `i2c-tools`)
  sets `GROUP="i2c"`. The latter sorts later so it wins the group, leaving the
  node `root:i2c` — but the `uaccess` tag from the former still applies, so
  systemd-logind grants an ACL to the active local seat:

  ```
  $ getfacl /dev/i2c-1   →   user:<you>:rw-
  ```

  In a desktop session this works with **no group membership at all**. Over SSH
  there's no seat, no ACL, and group membership becomes the only route — and it
  must be `i2c`, not `dialout`, because `i2c-tools` won the `GROUP` assignment.
  Check `getfacl` before chasing groups.
- **No system tray.** GNOME on Wayland has no XEmbed tray, so PyQt5's
  `QSystemTrayIcon` never appears — the app runs fine and shows nothing. The
  working path is StatusNotifierItem via `AyatanaAppIndicator3`, which the
  default-enabled `ubuntu-appindicators` extension renders.
- **`config.txt` is at `/boot/firmware/config.txt`**, and this image uses
  `os_prefix=current/`.
- **There is no `/boot/firmware/overlays/`, and the directory that looks like it
  is a trap.** The tryboot layout puts overlays in
  `/boot/firmware/current/overlays/`, which flash-kernel rebuilds from the
  kernel package on every kernel upgrade — so a hand-placed `.dtbo` survives
  until the next `linux-raspi` and then vanishes without a word. The one
  directory flash-kernel searches that no package owns is
  `/etc/flash-kernel/dtbs/`. Often the overlay is avoidable entirely: an I2C
  device can be instantiated from userspace via a udev rule
  (`Documentation/i2c/instantiating-devices.rst`), which needs no reboot. See
  `ups/driver/`.
- **Suspend and hibernate do not exist.** `linux-raspi` is built with
  `CONFIG_SUSPEND` and `CONFIG_HIBERNATION` unset, so `/sys/power/state` is an
  empty file and `/sys/power/disk` is absent. Nothing configurable brings them
  back; it needs a rebuilt kernel, and on BCM2712 s2idle is [not supported
  upstream](https://www.phoronix.com/news/Suspend-To-Idle-Raspberry-Pi) anyway.
  Hibernation is the more plausible of the two, since it needs no SoC sleep
  state.
- **A HAT battery is invisible to the desktop until the kernel knows about it.**
  UPower enumerates `/sys/class/power_supply` and has no plugin interface, so no
  userspace script — however correct — can produce a low-battery warning or a
  critical-shutdown policy. That takes a `power_supply` class driver;
  `ups/driver/` is one.
- **Don't add the Raspberry Pi apt repo.** Its packages target Raspberry Pi OS
  and mixing them into Ubuntu breaks the libcamera stack. Ubuntu 26.04 already
  ships libcamera 0.7.0, `rpicam-apps`, and `python3-picamera2`.
- **Python is 3.14**, so upstream wheels for Pi imaging/HAT libraries frequently
  don't exist. Prefer distro packages; `smbus2` replaces the unpackaged `smbus`.
- **CMake is 4.2**, which removed support for `cmake_minimum_required(VERSION
  <3.5)`. Raspberry Pi OS ships CMake 3.x, where that's only deprecated — so
  vendor source trees (HailoRT and its bundled deps) fail to configure here until
  you pass `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.
- **`sudo poweroff` in vendor scripts** assumes passwordless sudo. `systemctl
  poweroff` is authorised by polkit for the active local session instead.
- **`sudo` needs a TTY**, which agent/automation contexts don't have. `pkexec`
  gets you a graphical polkit prompt instead — but it exports `PKEXEC_UID`, not
  `SUDO_USER`, so scripts that resolve "the real user" must handle both or they
  will silently configure `root`. See `common/lib.sh`.

## Not an Ubuntu problem: the vendor's own register decode

Waveshare's demo reads register `0x02` and treats bits 5/6/7 as three mutually
exclusive states in an `if/elif` chain — "fast charging", "charging",
"discharge". Their [register manual][reg] says those are *independent flags*
(bit7 charging, bit6 fast charging, bit5 **VBUS present** — not discharging), and
that the real charge stage is in bits 0–2, which the demo never reads.

On this deck register `0x02` reads `0xe5`, with all three bits set at once, so
the demo reports "Fast Charging state" while the pack measurably drains. The
driver here decodes the documented layout and derives charge direction from the
signed current register instead. Their signed-current conversion is also off by
one (`-= 0xFFFF` where two's complement needs `0x10000`).

[reg]: https://www.waveshare.com/wiki/UPS_HAT_(E)_Register
