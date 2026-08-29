# UPS HAT (E) — kernel driver

A `power_supply` class driver for the Waveshare UPS HAT (E), so the deck's
battery is a battery as far as the rest of the system is concerned.

```bash
sudo bash install-driver.sh              # install, build via DKMS, bind
sudo bash install-driver.sh --uninstall  # and back out again
```

## Why this exists when `../ups_hat_e.py` already works

The Python driver reads the board correctly and the indicator drew a battery in
the top bar. That is not the same thing as the machine *having* a battery.

Everything that makes a laptop feel like a laptop when it is unplugged — the
power menu, the low-battery warning, "1:47 remaining", the automatic shutdown
before the cells are damaged, GNOME's Power panel, any application asking "am I
on battery?" — is UPower asking the kernel. UPower enumerates
`/sys/class/power_supply` and has no plugin interface for "a Python service
knows the answer". Before this driver, `upower -e` on this deck listed a
wireless mouse and nothing else. The indicator could only ever paint a picture
of a battery *next to* the real status area; nothing downstream could see the
pack at all.

So the port moved down a layer. Same register decoding, same two vendor bugs
avoided — see the comments in `ups-hat-e.c` and in `../ups_hat_e.py` — but
registered with the kernel instead of drawn on the screen.

So the indicator is retired:

```bash
systemctl --user disable --now cyberdeck-ups.service
```

The one thing it had that GNOME does not is per-cell voltage, charge stage and
link health — and there is no way to attach those to the system battery menu.
The popover is Quick Settings, built from UPower's schema, and UPower has no
mechanism for vendor-specific properties, so there is nothing to surface even if
the menu were configurable. Putting them there means a GNOME Shell extension in
JavaScript, which is a separate project and the component most likely to break
on every GNOME major. Not worth it for numbers that are one command away:

```bash
python3 ../ups_hat_e.py --watch
cat /sys/class/power_supply/BAT0/cell_voltages
```

`indicator.py` stays in the tree — it is the fallback when this driver is not
installed, and its notes on why a PyQt5 `QSystemTrayIcon` can never work under
Wayland are the kind of thing this repo exists to record. If you do run it
alongside the driver, it must be **restarted** after the driver is installed.
That is not optional: once the driver binds, the kernel owns `0x2d` and
userspace I2C to that address returns `EBUSY` — `i2cdetect -y 1` prints `UU`
where the address used to be. Nothing announces this. The indicator's poll loop
catches `OSError` and keeps running, so the top bar shows `--` forever. Both
`indicator.py` and `ups_hat_e.py` pick their backend at startup via
`open_ups()`, preferring the driver and falling back to direct I2C.

Reading through the driver also settles something subtler. Two independent
decoders of the same registers drift: the driver applies a 30 mA current
deadband and the Python decode originally did not, so a pack sitting at 100%
produced "fully charged" in GNOME and "charging" in the top bar — same register,
same instant, both defensible. `CURRENT_DEADBAND_MA` in `../ups_hat_e.py` now
mirrors `UPS_CURRENT_DEADBAND_UA` here.

## What it registers

Two devices, both children of the I2C client at `1-002d`:

| Device | Type | What it is |
| --- | --- | --- |
| `BAT0` | `POWER_SUPPLY_TYPE_BATTERY` | the 4S pack, via the BQ4050 gauge |
| `AC0` | `POWER_SUPPLY_TYPE_MAINS` | the barrel-jack input, via the IP2368 |

Both are needed. A battery on its own leaves UPower inferring wall power from
charge direction; the `MAINS` device makes it a fact, and is what puts the plug
on the icon.

Two details decide whether the desktop treats this as *the machine's* battery
rather than as a peripheral like the mouse:

- `POWER_SUPPLY_PROP_SCOPE` returns `SYSTEM`. Without it UPower files the device
  under peripherals and GNOME never adopts it.
- The first I2C sample is taken **before** `devm_power_supply_register()`.
  UPower reads the entire property set the instant the uevent lands, and a
  device that answers `-EAGAIN` to all of it during enumeration can be written
  off and never retried.

Beyond the standard properties, the board exposes what `power_supply` has no
vocabulary for:

```
$ cat /sys/class/power_supply/BAT0/cell_voltages
4184000 4183000 4186000 4195000
$ cat /sys/class/power_supply/BAT0/charge_stage
constant voltage
$ cat /sys/class/power_supply/BAT0/link_status
gauge=ok charger=ok
```

Per-cell voltage matters on a 4S pack because one collapsing cell is invisible
in the aggregate percentage, and it is the weakest cell — not the state of
charge — that decides `CAPACITY_LEVEL=Critical`.

## Module parameters

```bash
# /etc/modprobe.d/ups-hat-e.conf
options ups-hat-e design_capacity_mah=5000
```

| Parameter | Default | |
| --- | --- | --- |
| `poll_interval` | `5` | seconds between I2C samples |
| `design_capacity_mah` | `0` | see below |
| `poweroff_cuts_power` | `0` | see below |

**`design_capacity_mah`** is unset because the HAT ships without cells and the
MCU exposes remaining charge but not the gauge's `FullChargeCapacity`, so
nothing on the board knows what a full pack is worth. `charge_full` is instead
back-computed from remaining ÷ percentage, recomputed only when the reported
percentage moves — recomputing every poll makes integer-percent quantisation
jitter the value by ~50 mAh. `charge_full_design` reports `-ENODATA` until you
tell it what you fitted, which is why GNOME shows a design capacity of 0 Wh.

**`poweroff_cuts_power`** registers a shutdown handler that writes `0x55` to the
MCU, telling it to drop the rail ~30 s after the Pi halts and restore it when a
charger is attached. This fixes something a bare Pi genuinely cannot do: on this
hardware `poweroff` leaves the board drawing from the pack indefinitely, so an
overnight "shutdown" can still flatten the cells.

It is off by default because the same command has a second half. Shut down while
the charger is *already* attached and the restart condition may be satisfied the
moment the rail drops — a shutdown that reboots. Whether that happens depends on
how the MCU edge-detects the charger, which the register manual does not
specify. **Untested on this deck, both ways.** Try it on the bench before
trusting it.

## How the driver gets bound

The Raspberry Pi OS answer is a device-tree overlay, and every guide says to
drop a `.dtbo` into `/boot/firmware/overlays/` and add a `dtoverlay=` line.
On Ubuntu that directory does not exist, and the obvious substitute is a trap:

- The boot partition is laid out for tryboot — `config.txt` sets
  `os_prefix=current/` — so overlays live in `/boot/firmware/current/overlays/`.
- flash-kernel **rebuilds that directory from the kernel package on every kernel
  upgrade** (`find_device_tree_overlays`, `/usr/share/flash-kernel/functions`).
  A `.dtbo` copied there by hand survives until the next `linux-raspi` and then
  silently disappears, taking the battery with it.

So the default here is `99-ups-hat-e.rules`, which instantiates the device from
userspace — a documented kernel interface, not a workaround
(`Documentation/i2c/instantiating-devices.rst`, "Method 4: Instantiate from
user-space"), meant for exactly this case: a device on a general-purpose bus
that firmware has no reason to know about. It needs no reboot and no boot
partition surgery, and writing `new_device` emits a `MODALIAS=i2c:ups-hat-e`
uevent, so udev autoloads the module by itself.

The rule matches `ENV{OF_ALIAS_0}=="i2c1"` rather than `KERNEL=="i2c-1"`. Linux
numbers I2C adapters in probe order and the Pi 5 has four of them — two on the
RP1, two on the SoC. `i2c-1` is the 40-pin header bus today; the device-tree
alias `i2c1` **is** the header bus by definition.

`ups-hat-e.dts` is the overlay route for anyone who wants it, along with the one
directory flash-kernel searches that no package owns
(`/etc/flash-kernel/dtbs/overlays/`). It compiles and applies cleanly onto
`bcm2712-rpi-5-b.dtb` — verified with `dtmerge`, which is as far as it has been
taken; the udev path is the one running here. Use one or the other: both will
race for `0x2d` and the loser logs `EBUSY`.

## DKMS

The module is registered with DKMS so it is rebuilt when a kernel lands. This is
not optional maintenance — an out-of-tree module that stops loading does not
announce itself, it just means the battery is missing after a reboot.

```bash
dkms status                       # ups-hat-e/1.0, 7.0.0-1017-raspi: installed
journalctl -k -b | grep ups-hat-e
```

## Sleep and hibernate

Not available, and not because of anything here. Ubuntu's `linux-raspi` is built
with `CONFIG_SUSPEND` and `CONFIG_HIBERNATION` both unset:

```
$ cat /sys/power/state       # empty file
$ ls /sys/power/disk         # does not exist
$ loginctl show ... CanSuspend / CanHibernate / CanHybridSleep   →   na
```

`systemctl suspend` cannot work regardless of what the battery reports. The arch
supports it (`CONFIG_ARCH_SUSPEND_POSSIBLE=y`); the flavour does not build it.

One useful consequence: UPower's documented fallback for `CriticalPowerAction`
is HybridSleep → Hibernate → PowerOff, logind correctly reports all sleep modes
as `na`, so the critical-battery action already resolves to a clean power-off at
`PercentageAction=2.0`. `/etc/UPower/UPower.conf` is deliberately left at its
default `CriticalPowerAction=HybridSleep`: pinning it to `PowerOff` would work
today but would also stop it from doing the right thing if hibernation ever gets
built.

## Verify

```bash
upower -i /org/freedesktop/UPower/devices/battery_BAT0
upower -i /org/freedesktop/UPower/devices/DisplayDevice   # what GNOME draws
cat /sys/class/power_supply/BAT0/{status,capacity,cell_voltages}
```

`power supply: yes` in the UPower output is the line that matters — it is
UPower's word for "this is the system's own battery", and it is what `SCOPE`
buys.
