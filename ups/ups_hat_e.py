"""Driver for the Waveshare UPS HAT (E).

Reads the on-board MCU at I2C address 0x2d. Register semantics follow Waveshare's
register manual, which is a *separate* wiki page from the product page and is not
reflected in their own demo code:

    https://www.waveshare.com/wiki/UPS_HAT_(E)_Register

The board carries a BQ4050 fuel gauge and an IP2368 charger behind that MCU --
not the INA219 the product page's section heading implies.

Differences from Waveshare's `ups.py` / `batteryTray.py` demo:

* **Charge state is decoded correctly.** The demo treats bits 5/6/7 of register
  0x02 as three mutually exclusive states in an if/elif chain ("discharge",
  "fast charging", "charging"). Per the register manual they are *independent
  flags* -- bit7 charging, bit6 fast charging, bit5 VBUS present -- and the
  actual charge stage lives in bits 0-2, which the demo never reads at all.
  On this machine all three bits read set simultaneously (0xe5), so the demo
  reports "Fast Charging state" while the pack is measurably discharging.
  Bit 5 in particular means "VBUS is powered", not "discharging".
* **Signed current fixed.** The demo does `current -= 0xFFFF`, off by one for
  every negative reading; two's complement needs `0x10000`.
* **0xFFFF time estimates are treated as "unknown"** rather than printed as
  65535 minutes.
* `smbus` -> `smbus2`: the old binding isn't packaged for Python 3.14 on Ubuntu.
* No shelling out to `i2cdetect`/`i2cset`, and `systemctl poweroff` instead of
  `sudo poweroff` (polkit authorises the active session without a password).

Two backends read the same board and produce the same `UpsStatus`:

* `UpsHatE` talks to the MCU over I2C directly, and needs nothing installed.
* `SysfsUpsHatE` reads the kernel driver in `driver/`, which registers the pack
  as `BAT0`. Prefer it when it is available -- see `open_ups()` for why.

Standalone usage:  python3 ups_hat_e.py [--watch]
"""

from __future__ import annotations

import argparse
import dataclasses
import enum
import pathlib
import time

from smbus2 import SMBus

I2C_BUS = 1
I2C_ADDR = 0x2D

REG_ID = 0x00  # fixed 0x0a
REG_CONTROL = 0x01  # fixed 0x0b; write 0x55 to power off + arm auto-restart
REG_CHARGE = 0x02  # charge flags + charge stage
REG_COMMS = 0x03  # BQ4050 / IP2368 link health
REG_VBUS = 0x10  # 6 bytes: voltage mV, current mA, power mW
REG_BATTERY = 0x20  # 12 bytes: mV, mA (signed), %, mAh, min-to-empty, min-to-full
REG_CELLS = 0x30  # 8 bytes: cell 1-4 voltages, mV
REG_SW_REVISION = 0x50  # 0x14 == v2.0

# Written to REG_CONTROL: cuts power to the Pi after ~30s, then restores it once
# a charger is detected. Shut the Pi down promptly after issuing this.
CMD_POWEROFF_RESTART_ON_CHARGE = 0x55

# Register 0x02 flag bits.
_CHARGING = 1 << 7
_FAST_CHARGING = 1 << 6
_VBUS_PRESENT = 1 << 5
_STAGE_MASK = 0b111

# Register 0x03 link-health bits.
_GAUGE_OK = 1 << 1  # BQ4050
_CHARGER_OK = 1 << 0  # IP2368

#: The 16-bit registers use 0xFFFF for "not available".
_UNKNOWN = 0xFFFF

#: Per-cell voltage below which the pack is considered critically low (mV).
LOW_CELL_MV = 3150

#: Charge current below which the pack counts as neither charging nor
#: discharging (mA). Mirrors UPS_CURRENT_DEADBAND_UA in driver/ups-hat-e.c, and
#: has to: a pack held at the constant-voltage stage settles to a few mA of
#: taper that crosses zero between samples, so without a deadband this file
#: reports "idle" or "charging" on alternate polls while the kernel driver --
#: reading the same register -- reports "fully charged" to the desktop. Two
#: defensible answers on screen at once is worse than either.
CURRENT_DEADBAND_MA = 30


class ChargeStage(enum.Enum):
    """Bits 0-2 of register 0x02."""

    STANDBY = 0
    TRICKLE = 1
    CONSTANT_CURRENT = 2
    CONSTANT_VOLTAGE = 3
    PENDING = 4
    FULL = 5
    TIMEOUT = 6

    @property
    def label(self) -> str:
        return self.name.replace("_", " ").lower()

    @classmethod
    def from_bits(cls, value: int) -> "ChargeStage | None":
        try:
            return cls(value & _STAGE_MASK)
        except ValueError:  # 0b111 is not defined by the manual
            return None


def _u16(data: list[int], index: int) -> int:
    return data[index] | data[index + 1] << 8


def _s16(data: list[int], index: int) -> int:
    value = _u16(data, index)
    return value - 0x10000 if value > 0x7FFF else value


def _optional_u16(data: list[int], index: int) -> int | None:
    value = _u16(data, index)
    return None if value == _UNKNOWN else value


@dataclasses.dataclass(frozen=True, slots=True)
class UpsStatus:
    # Register 0x02
    charging_flag: bool
    fast_charging_flag: bool
    vbus_present: bool
    stage: ChargeStage | None

    # Register 0x03
    gauge_ok: bool
    charger_ok: bool

    vbus_mv: int
    vbus_ma: int
    vbus_mw: int

    battery_mv: int
    battery_ma: int  # positive = charging, negative = discharging
    percent: int
    remaining_mah: int
    minutes_to_empty: int | None
    minutes_to_full: int | None

    cell_mv: tuple[int, int, int, int]

    @property
    def is_charging(self) -> bool:
        """Whether charge is actually flowing *into* the pack.

        Deliberately derived from measured current rather than the flag bits:
        the flags stay set while VBUS is present even when the charger has
        stopped delivering, which is exactly the case the vendor demo gets wrong.
        """
        return self.battery_ma > CURRENT_DEADBAND_MA

    @property
    def is_discharging(self) -> bool:
        return self.battery_ma < -CURRENT_DEADBAND_MA

    @property
    def is_full(self) -> bool:
        # The percentage counts as well as the stage: the gauge reports 100%
        # while the charger is still in constant voltage, and calling that
        # anything other than full invites the question of what is missing.
        return self.stage is ChargeStage.FULL or self.percent >= 100

    @property
    def is_critical(self) -> bool:
        return not self.is_charging and min(self.cell_mv) < LOW_CELL_MV

    @property
    def minutes_remaining(self) -> int | None:
        return self.minutes_to_full if self.is_charging else self.minutes_to_empty

    def state_label(self) -> str:
        # Same order of reasoning as ups_hat_e_status() in the kernel driver, so
        # that this and the desktop cannot describe the pack differently.
        #
        # Measured current is checked before the stage field on purpose. The MCU
        # keeps reporting stage=FULL once charging completes, but if the input
        # then stops delivering, the pack quietly starts supplying the load --
        # trusting the stage here would show "full" while the battery drains.
        # That draw is far outside the deadband, so it is caught here first.
        if self.is_charging:
            return "fast charging" if self.fast_charging_flag else "charging"
        if self.is_discharging:
            return "on battery (input present)" if self.vbus_present else "on battery"
        if self.is_full:
            return "full"
        return "idle (input present)" if self.vbus_present else "idle"

    def summary(self) -> str:
        return (
            f"{self.percent}%  {self.battery_mv / 1000:.2f}V  "
            f"{self.battery_ma / 1000:+.2f}A  ({self.state_label()})"
        )


class UpsHatE:
    """Talks to the UPS HAT (E) MCU over I2C."""

    supports_poweroff = True

    def __init__(self, bus: int = I2C_BUS, address: int = I2C_ADDR) -> None:
        self._bus_number = bus
        self._address = address
        self._bus: SMBus | None = None

    def open(self) -> "UpsHatE":
        if self._bus is None:
            self._bus = SMBus(self._bus_number)
        return self

    def close(self) -> None:
        if self._bus is not None:
            self._bus.close()
            self._bus = None

    def __enter__(self) -> "UpsHatE":
        return self.open()

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def _require_bus(self) -> SMBus:
        if self._bus is None:
            raise RuntimeError("UpsHatE is not open; use it as a context manager")
        return self._bus

    def _read(self, register: int, length: int) -> list[int]:
        return self._require_bus().read_i2c_block_data(self._address, register, length)

    def software_revision(self) -> str:
        """Firmware revision, e.g. 0x14 -> '2.0'."""
        raw = self._read(REG_SW_REVISION, 1)[0]
        return f"{raw // 10}.{raw % 10}"

    def read(self) -> UpsStatus:
        # 0x02 and 0x03 are adjacent, so one block read covers both.
        charge, comms = self._read(REG_CHARGE, 2)
        vbus = self._read(REG_VBUS, 6)
        battery = self._read(REG_BATTERY, 12)
        cells = self._read(REG_CELLS, 8)

        return UpsStatus(
            charging_flag=bool(charge & _CHARGING),
            fast_charging_flag=bool(charge & _FAST_CHARGING),
            vbus_present=bool(charge & _VBUS_PRESENT),
            stage=ChargeStage.from_bits(charge),
            gauge_ok=bool(comms & _GAUGE_OK),
            charger_ok=bool(comms & _CHARGER_OK),
            vbus_mv=_u16(vbus, 0),
            vbus_ma=_u16(vbus, 2),
            vbus_mw=_u16(vbus, 4),
            battery_mv=_u16(battery, 0),
            battery_ma=_s16(battery, 2),
            percent=_u16(battery, 4),
            remaining_mah=_u16(battery, 6),
            minutes_to_empty=_optional_u16(battery, 8),
            minutes_to_full=_optional_u16(battery, 10),
            cell_mv=(
                _u16(cells, 0),
                _u16(cells, 2),
                _u16(cells, 4),
                _u16(cells, 6),
            ),
        )

    def poweroff_until_charged(self) -> None:
        """Cut power, then restore it automatically when a charger is connected."""
        self._require_bus().write_byte_data(
            self._address, REG_CONTROL, CMD_POWEROFF_RESTART_ON_CHARGE
        )


SYSFS_ROOT = pathlib.Path("/sys/class/power_supply")

#: Charge stages keyed by the label the kernel driver prints, which is generated
#: from the same register manual as ChargeStage above.
_STAGE_BY_LABEL = {stage.label: stage for stage in ChargeStage}


class SysfsUpsHatE:
    """Reads the board through the kernel driver instead of over I2C.

    Same registers, same board, same UpsStatus -- but read via
    /sys/class/power_supply rather than by opening the bus. Worth preferring
    whenever the module is loaded, for a reason that is not really about
    efficiency: two independent decoders of the same registers drift apart.

    The driver applies a 30 mA deadband to charge current so that the taper at
    the end of a charge does not flip its state every poll (see the comment on
    UPS_CURRENT_DEADBAND_UA in driver/ups-hat-e.c). This file's `is_charging`
    has no such deadband. Run both against a pack sitting at 100% and the
    desktop says "fully charged" while this says "charging" -- both defensible,
    both from the same register, and impossible to explain to anyone looking at
    the screen. Reading the driver makes that disagreement structurally
    impossible, and keeps a single reader on the I2C bus as a side benefit.
    """

    #: The MCU can be told to cut its rail, but only over I2C -- and with the
    #: driver loaded, critical-battery policy belongs to UPower anyway.
    supports_poweroff = False

    def __init__(self, battery: str = "BAT0", mains: str = "AC0") -> None:
        self._battery = SYSFS_ROOT / battery
        self._mains = SYSFS_ROOT / mains

    @classmethod
    def available(cls, battery: str = "BAT0") -> bool:
        """Whether *our* driver is what registered BAT0.

        The model name is checked rather than the directory alone: BAT0 is the
        conventional name for a system battery and finding one says nothing
        about which driver put it there.
        """
        try:
            model = (SYSFS_ROOT / battery / "model_name").read_text().strip()
        except OSError:
            return False
        return model == "UPS HAT (E)"

    def open(self) -> "SysfsUpsHatE":
        return self

    def close(self) -> None:
        pass

    def __enter__(self) -> "SysfsUpsHatE":
        return self

    def __exit__(self, *_exc: object) -> None:
        pass

    @staticmethod
    def _text(path: pathlib.Path) -> str | None:
        # Properties the driver answers with -ENODATA -- an absent runtime
        # estimate, an unset design capacity -- surface as EOPNOTSUPP on read,
        # which is the sysfs spelling of "no value", not of "broken".
        try:
            return path.read_text().strip()
        except OSError:
            return None

    def _int(self, node: pathlib.Path, name: str, scale: int = 1) -> int:
        value = self._text(node / name)
        if value is None:
            raise OSError(f"{node / name} is unreadable")
        return int(value) // scale

    def _optional_minutes(self, name: str) -> int | None:
        value = self._text(self._battery / name)
        return None if value is None else int(value) // 60

    def software_revision(self) -> str:
        # The driver logs the revision at probe but does not export it; the
        # journal is the honest place to point rather than inventing a number.
        return "see 'journalctl -k | grep ups-hat-e'"

    def read(self) -> UpsStatus:
        flags = dict(
            pair.split("=", 1)
            for pair in (self._text(self._battery / "charge_flags") or "").split()
        )
        link = dict(
            pair.split("=", 1)
            for pair in (self._text(self._battery / "link_status") or "").split()
        )
        cells = [
            int(uv) // 1000
            for uv in (self._text(self._battery / "cell_voltages") or "").split()
        ]
        stage_label = self._text(self._battery / "charge_stage") or ""

        vbus_mv = self._int(self._mains, "voltage_now", 1000)
        vbus_ma = self._int(self._mains, "current_now", 1000)
        # power_now was added to AC0 after the first version of the driver, so
        # fall back to the product rather than refusing to read a board that is
        # otherwise answering perfectly well.
        vbus_uw = self._text(self._mains / "power_now")
        vbus_mw = int(vbus_uw) // 1000 if vbus_uw else vbus_mv * vbus_ma // 1000

        return UpsStatus(
            charging_flag=flags.get("charging") == "1",
            fast_charging_flag=flags.get("fast_charging") == "1",
            vbus_present=flags.get("vbus_present") == "1",
            stage=_STAGE_BY_LABEL.get(stage_label),
            gauge_ok=link.get("gauge") == "ok",
            charger_ok=link.get("charger") == "ok",
            vbus_mv=vbus_mv,
            vbus_ma=vbus_ma,
            vbus_mw=vbus_mw,
            battery_mv=self._int(self._battery, "voltage_now", 1000),
            battery_ma=self._int(self._battery, "current_now", 1000),
            percent=self._int(self._battery, "capacity"),
            remaining_mah=self._int(self._battery, "charge_now", 1000),
            minutes_to_empty=self._optional_minutes("time_to_empty_now"),
            minutes_to_full=self._optional_minutes("time_to_full_now"),
            cell_mv=tuple(cells),  # type: ignore[arg-type]
        )


def open_ups(prefer_kernel: bool = True):
    """Open the best available reader for the HAT.

    Prefers the kernel driver when it is loaded, falls back to talking to the
    MCU directly. Callers that need `poweroff_until_charged()` should check
    `supports_poweroff` rather than assuming which one they got.
    """
    if prefer_kernel and SysfsUpsHatE.available():
        return SysfsUpsHatE().open()
    return UpsHatE().open()


def _print(status: UpsStatus) -> None:
    print(status.summary())
    stage = status.stage.label if status.stage else "unknown"
    print(f"  stage      {stage}"
          f"   [charging={status.charging_flag} fast={status.fast_charging_flag}"
          f" vbus={status.vbus_present}]")
    print(f"  input      {status.vbus_mv / 1000:.2f}V "
          f"{status.vbus_ma / 1000:.2f}A {status.vbus_mw / 1000:.1f}W")
    remaining = status.minutes_remaining
    verb = "to full" if status.is_charging else "to empty"
    estimate = f"{remaining} min {verb}" if remaining is not None else "no estimate"
    print(f"  capacity   {status.remaining_mah} mAh, {estimate}")
    print("  cells      " + " ".join(f"{mv}mV" for mv in status.cell_mv))
    if not (status.gauge_ok and status.charger_ok):
        print(f"  LINK FAULT: gauge_ok={status.gauge_ok} charger_ok={status.charger_ok}")
    if status.is_critical:
        print("  CRITICAL: cell below safe voltage")


def _main() -> int:
    parser = argparse.ArgumentParser(description="Read the Waveshare UPS HAT (E).")
    parser.add_argument("--watch", action="store_true", help="poll continuously")
    parser.add_argument("--interval", type=float, default=2.0, help="seconds between polls")
    parser.add_argument("--i2c", action="store_true",
                        help="read the MCU directly, bypassing the kernel driver")
    args = parser.parse_args()

    if args.i2c and SysfsUpsHatE.available():
        # Worth saying plainly rather than letting errno 16 speak for itself:
        # the kernel driver has claimed 0x2d, so the address is no longer
        # addressable from userspace. i2cdetect shows `UU` there instead of the
        # address. This is not a fault to work around -- forcing past a bound
        # driver means two masters interleaving transactions on the same MCU.
        print("The kernel driver currently owns 0x2d, so --i2c cannot read it.\n"
              "Either drop --i2c, or unbind the driver first:\n"
              "  sudo bash driver/install-driver.sh --uninstall")
        return 1

    with open_ups(prefer_kernel=not args.i2c) as ups:
        via = "kernel driver" if isinstance(ups, SysfsUpsHatE) else "I2C"
        if isinstance(ups, SysfsUpsHatE):
            print(f"UPS HAT (E) via {via}\n")
        else:
            print(f"UPS HAT (E) via {via}, firmware v{ups.software_revision()}\n")
        while True:
            _print(ups.read())
            if not args.watch:
                return 0
            print()
            time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(_main())
