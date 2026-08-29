#!/usr/bin/env python3
"""GNOME top-bar indicator for the Waveshare UPS HAT (E).

Superseded by the kernel driver in `driver/`, which registers the pack as a real
`power_supply` device so GNOME draws the battery itself. This is kept as the
fallback for running without that driver, and for the porting notes below.

Replaces Waveshare's PyQt5 `batteryTray.py`, which cannot work on this machine:

* `QSystemTrayIcon` needs an XEmbed system tray. GNOME dropped that years ago and
  this session is Wayland, so the icon would simply never appear. GNOME speaks
  StatusNotifierItem, which is what AyatanaAppIndicator3 emits -- and the
  `ubuntu-appindicators` extension is enabled by default here.
* The vendor launcher hardcodes `DISPLAY=':0.0'` and `/home/pi/...`.
* Icons were bundled PNGs; we use the theme's symbolic battery icons so the
  indicator matches the rest of the top bar in both light and dark styles.

It reads through the kernel driver in `driver/` when that is loaded, and talks
to the MCU directly otherwise -- see `open_ups()`. That is not a preference: once
the driver claims 0x2d, the kernel owns the address and userspace I2C to it
returns EBUSY (`i2cdetect -y 1` shows `UU` rather than `2d`). An indicator built
on direct I2C does not fail loudly at that point, it just quietly renders "--"
forever, because the poll loop catches OSError and carries on.

Run directly for a foreground test, or install as a user service:
    bash install-indicator.sh
"""

from __future__ import annotations

import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

Notify = None
for _notify_abi in ("0.7", "0.8"):
    try:
        gi.require_version("Notify", _notify_abi)
        from gi.repository import Notify  # noqa: F811

        break
    except (ValueError, ImportError):  # libnotify GIR absent or different ABI
        Notify = None

from ups_hat_e import UpsStatus, open_ups  # noqa: E402

APP_ID = "cyberdeck-ups"
POLL_SECONDS = 5

#: Seconds of continuous critical-battery readings before we shut down. The UPS
#: MCU is told to restore power once a charger is plugged back in.
SHUTDOWN_GRACE_SECONDS = 60


def _battery_icon(status: UpsStatus) -> str:
    """Pick a themed symbolic icon for the current charge level.

    The plug indication keys off vbus_present, not is_charging. They are not the
    same question and conflating them is a real bug: is_charging means "current
    is flowing into the pack", and the driver's 30 mA deadband deliberately
    makes that false once a charge tapers off. Keyed off is_charging, the icon
    dropped its plug the moment the pack reached full and showed a plain battery
    while the deck was sitting on wall power. What the icon is asked to convey
    is "am I on external power", which is exactly what vbus_present says.
    """
    level = max(0, min(100, round(status.percent / 10) * 10))
    if status.vbus_present:
        suffix = "-charged" if status.is_full else "-charging"
    else:
        suffix = ""
    candidates = [
        f"battery-level-{level}{suffix}-symbolic",
        f"battery-level-{level}-charging-symbolic" if status.vbus_present else
        f"battery-level-{level}-symbolic",
        f"battery-level-{level}-symbolic",
    ]
    if status.percent >= 80:
        candidates.append("battery-full-symbolic")
    elif status.percent >= 40:
        candidates.append("battery-good-symbolic")
    elif status.percent >= 15:
        candidates.append("battery-low-symbolic")
    else:
        candidates.append("battery-caution-symbolic")

    theme = Gtk.IconTheme.get_default()
    for name in candidates:
        if theme.has_icon(name):
            return name
    return "battery-symbolic"


class UpsIndicator:
    def __init__(self) -> None:
        self._ups = open_ups()
        self._critical_since: float | None = None
        self._notification = None

        self._indicator = AppIndicator.Indicator.new(
            APP_ID,
            "battery-symbolic",
            AppIndicator.IndicatorCategory.HARDWARE,
        )
        self._indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)

        # Menu rows are rebuilt in place on each poll; AppIndicator requires a
        # menu to be attached or the icon is not shown at all.
        self._rows: dict[str, Gtk.MenuItem] = {}
        menu = Gtk.Menu()
        for key in (
            "state",
            "battery",
            "capacity",
            "runtime",
            "input",
            "cells",
        ):
            item = Gtk.MenuItem(label="…")
            item.set_sensitive(False)
            menu.append(item)
            self._rows[key] = item

        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda _w: Gtk.main_quit())
        menu.append(quit_item)
        menu.show_all()
        self._indicator.set_menu(menu)

        if Notify is not None:
            Notify.init(APP_ID)

        self._refresh()
        GLib.timeout_add_seconds(POLL_SECONDS, self._refresh)

    def _refresh(self) -> bool:
        try:
            status = self._ups.read()
        except OSError as exc:
            # Transient read errors happen on a HAT header; keep the last good
            # reading on screen. Naming the backend matters here -- "I2C error"
            # while actually reading sysfs sends you to debug the wrong layer.
            source = "sysfs" if not self._ups.supports_poweroff else "I2C"
            self._indicator.set_label("--", "100%")
            self._rows["state"].set_label(f"{source} read error: {exc}")
            return True

        self._indicator.set_icon_full(_battery_icon(status), status.summary())
        self._indicator.set_label(f"{status.percent}%", "100%")

        stage = status.stage.label if status.stage else "unknown"
        self._rows["state"].set_label(f"State: {status.state_label()} ({stage})")
        self._rows["battery"].set_label(
            f"Battery: {status.battery_mv / 1000:.2f} V  "
            f"{status.battery_ma / 1000:+.2f} A"
        )
        self._rows["capacity"].set_label(
            f"Capacity: {status.percent}%  ({status.remaining_mah} mAh)"
        )
        # runtime_label() handles the 0xFFFF "no estimate" the MCU reports once
        # the pack is full or right after a load change, falling back to charge
        # over current rather than showing a bare dash.
        self._rows["runtime"].set_label(f"Estimate: {status.runtime_label()}")
        self._rows["input"].set_label(
            f"Input: {status.vbus_mv / 1000:.2f} V  "
            f"{status.vbus_ma / 1000:.2f} A  {status.vbus_mw / 1000:.1f} W"
        )
        self._rows["cells"].set_label(
            "Cells: " + "  ".join(f"{mv / 1000:.2f}V" for mv in status.cell_mv)
        )

        self._handle_critical(status)
        return True  # keep the timeout registered

    def _handle_critical(self, status: UpsStatus) -> None:
        if not status.is_critical:
            self._critical_since = None
            return

        if self._critical_since is None:
            self._critical_since = GLib.get_monotonic_time() / 1_000_000
            self._notify(
                "Battery critically low",
                f"A cell is below {min(status.cell_mv)} mV. Connect power — "
                f"shutting down in {SHUTDOWN_GRACE_SECONDS}s.",
            )
            return

        elapsed = GLib.get_monotonic_time() / 1_000_000 - self._critical_since
        if elapsed >= SHUTDOWN_GRACE_SECONDS:
            self._shutdown()

    def _notify(self, title: str, body: str) -> None:
        if Notify is None:
            print(f"{title}: {body}", file=sys.stderr)
            return
        self._notification = Notify.Notification.new(title, body, "battery-caution-symbolic")
        self._notification.set_urgency(Notify.Urgency.CRITICAL)
        self._notification.show()

    def _shutdown(self) -> None:
        # Ask the HAT to restore power once a charger is connected, then halt.
        # systemctl (not `sudo poweroff`) so polkit authorises the active session
        # without a password.
        #
        # Arming the HAT is only possible over I2C, so with the kernel driver
        # loaded that half belongs to the driver's poweroff_cuts_power module
        # parameter, which hooks the same command into the system's own shutdown
        # path. This still halts either way -- it fires on a collapsing *cell*,
        # which UPower's percentage-based policy will not catch, so the two are
        # layered rather than competing.
        if self._ups.supports_poweroff:
            try:
                self._ups.poweroff_until_charged()
            except OSError as exc:
                print(f"could not arm UPS auto-restart: {exc}", file=sys.stderr)
        subprocess.Popen(["systemctl", "poweroff"])
        Gtk.main_quit()


def main() -> int:
    UpsIndicator()
    Gtk.main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
