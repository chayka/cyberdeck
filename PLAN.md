# Plan

## The thesis

This cyberdeck runs **Ubuntu 26.04**, but essentially all Raspberry Pi peripheral
code — vendor demos, HAT drivers, tutorials — is written for **Raspberry Pi OS**.
When that code fails here, the cause is almost never the hardware and almost
never the peripheral logic. It's the platform assumptions underneath it:

- a group that doesn't exist (`i2c`)
- a display server that was replaced (X11/XEmbed tray → Wayland/StatusNotifierItem)
- an apt repo that isn't configured (`hailo-all`, and the Pi's libcamera builds)
- paths that moved (`/boot/config.txt` → `/boot/firmware/config.txt`)
- a Python that's too new for the wheels (3.14)
- privileges that aren't free (`sudo poweroff` assuming passwordless sudo)

So the work is: **strip the Raspberry Pi OS assumptions out, keep the hardware
logic, and write down why each change was needed.** The "why" is the actual value
here — the fixes are mostly small once the cause is identified, and nobody else
seems to have documented them in one place.

Secondary goal: publish this. Hence one self-contained directory per peripheral,
no vendor code redistributed, reasoning in comments rather than commit messages.

## Status

| Peripheral | State |
| --- | --- |
| UPS HAT (E) | **Working**, verified against hardware at `0x2d`, firmware v2.0. |
| UPS as a system battery | **Working** — `ups/driver/`, a `power_supply` kernel module. `BAT0`/`AC0` in sysfs, adopted by UPower, drawn by GNOME. |
| Top-bar indicator | **Retired** — GNOME draws the battery itself now. Kept in the tree as the no-driver fallback; reads through the driver when one is loaded. |
| Camera Module 3 | **Working** — `imx708_wide_noir`, up to 4608x2592. |
| Hailo-8 | **Working** — driver v4.24.0 via DKMS, HailoRT installed, YOLOv8s at ~174 FPS. |
| Camera → Hailo | **Working** — `hailo/detect.py`, verified detecting a bottle at 81%. |
| Python envs | **Done** — per-peripheral venvs with `--system-site-packages`. |

## Next direction: ROS 2

Wrap camera + Hailo inference into a ROS 2 module — a node publishing detections
(presumably `vision_msgs/Detection2DArray`) from the existing pipeline.

The hard part is already reusable: `hailo/detect.py`'s `Detector` holds a
persistent HailoRT pipeline and returns per-class normalised boxes, which maps
almost directly onto a detections publisher. This should be wrapping, not
re-engineering.

**Settle this before designing anything:** ROS 2 LTS releases have historically
targeted the *previous* Ubuntu LTS (Jazzy → 24.04), so `apt` may have no ROS 2
packages for Resolute at all. If so the options are build-from-source or a
container — a fork in the road worth resolving first, not three hours in.

Second consideration: this machine is Python 3.14 and `rclpy` may lag. ROS 2 also
expects the *system* interpreter, which cuts against the per-project venv pattern
below. A container likely resolves both problems at once — the first real use for
Docker on this deck.

## Loose ends

1. Three things in `ups/driver/` are shipped but unverified, in descending order
   of how much they matter:
   - `poweroff_cuts_power=1` (off by default) would let a shutdown actually cut
     the rail instead of letting the Pi drain the pack overnight — but the same
     command re-arms on charger detect, so shutting down while plugged in may
     reboot the deck. Needs bench testing both plugged and unplugged.
   - `design_capacity_mah` is unset, so GNOME shows a design capacity of 0 Wh.
     Set it to whatever the fitted 21700s are rated at.
   - `ups-hat-e.dts` compiles and applies to `bcm2712-rpi-5-b.dtb` under
     `dtmerge`, but has never been booted; the udev rule is the tested path.
2. **The critical-battery shutdown has never been exercised end-to-end.** The
   pieces are verified — UPower runs as a system service independent of any
   login session, `CanPowerOff` is `challenge`, and the fallback chain resolves
   past two unavailable sleep modes — but nothing has actually run the pack down
   to 2% to watch it fire. Worth doing deliberately once, on a day when losing
   the session does not matter. Note this is a real gain over the old indicator
   either way: that watchdog was a `systemd --user` unit bound to
   `graphical-session.target`, so it did not run at GDM, over SSH, or before
   login.
3. Live preview mode of `detect.py` has never been eyeballed (needs a human at the
   screen). `--still` and `--stream` are both verified.
4. **Reboot test outstanding** — everything is configured to persist, but that is
   a claim, not a result.
5. Streaming runs at ~10.7 fps, limited by CPU-side letterboxing, PIL drawing and
   JPEG encoding — not by the accelerator, which does yolov8s at 174 fps. Hardware
   JPEG encoding via Picamera2's encoder would be the real fix.
6. Possible hardware issue: the UPS showed input present at 15.13 V but ~0.01 A
   while the pack discharged at 0.65 A. May just be recharge hysteresis at 96%; if
   it persists, the deck drains the battery while apparently plugged in.
   **Not reproducing as of 2026-08-29**: with the pack at 100% in the
   constant-voltage stage, `AC0` reads 15.01 V at 798 mA (~12 W) while `BAT0`
   takes 5 mA — the supply is carrying the load as it should. That is a
   different charge stage from the original observation, though, so it is
   evidence rather than a resolution. Watch `AC0/current_now` once the stage
   reaches `full`; the driver makes this a one-line check now.
7. ~~Optional: a UPower-compatible daemon would put the UPS in GNOME's real
   battery menu.~~ **Done**, and not as a daemon: UPower has no plugin
   interface, it reads `/sys/class/power_supply`. So `ups/driver/` is a kernel
   module. `upower -i .../battery_BAT0` reports `power supply: yes`.
8. Hailo model compilation (Dataflow Compiler) only matters if custom models are
   ever needed; it pins Python 3.10/3.11 and belongs in a container.

## Settled: no sleep, and no local kernel to get it

`systemctl suspend` and `systemctl hibernate` cannot work on this deck, and the
reason is below the driver layer: Ubuntu's `linux-raspi` is built with
`CONFIG_SUSPEND` and `CONFIG_HIBERNATION` unset. `/sys/power/state` is an empty
file, `/sys/power/disk` is absent, and logind reports every sleep mode as `na`
— which is why GNOME shows no Suspend entry. `CONFIG_ARCH_SUSPEND_POSSIBLE=y`,
so this is a flavour decision, not an architecture limit.

Getting either back means a rebuilt kernel. **Decided 2026-08-29: not doing
that.** It would mean carrying a kernel `apt` keeps trying to replace, plus DKMS
rebuilds for `hailo_pci` and `ups-hat-e` against it — a permanent maintenance
cost for one feature, on a deck whose entire premise is staying on stock Ubuntu
packages.

Recorded so it does not get re-litigated, along with what the answer would have
been:

- **Suspend** was never plausible regardless. Raspberry Pi s2idle work [targets
  BCM2835, not the Pi 5's BCM2712](https://www.phoronix.com/news/Suspend-To-Idle-Raspberry-Pi),
  and the long-standing Pi pattern is [suspends fine, never
  resumes](https://github.com/raspberrypi/linux/issues/2198).
- **Hibernate** was the half that could have worked, needing no SoC sleep state:
  freeze, write RAM to swap, power off, resume through an ordinary boot. It
  would have needed `CONFIG_HIBERNATION=y`, swap at least the size of RAM
  (currently a 1 GB swapfile against 15 GB), and `resume=`/`resume_offset=` on
  the cmdline.

The useful consolation is that the thing sleep would have protected — not
running the pack flat — is handled anyway. UPower's documented fallback for
`CriticalPowerAction` is HybridSleep → Hibernate → PowerOff, and with all sleep
modes unavailable it resolves to a clean power-off at `PercentageAction=2.0`.
`/etc/UPower/UPower.conf` is deliberately left at its default rather than pinned
to `PowerOff`: pinning works today but would stop it doing the right thing if
hibernation ever arrives.

## Open hardware question

The UPS reports input present at 15.13 V but drawing ~0.01 A, while the pack
discharges at ~0.65 A — capacity fell 4599 → 4595 mAh over 20 s with the charger
connected. Charge stage reads `full`, so the charger has terminated and is not
carrying the load. Worth checking the supply and cable: a Pi 5 with the AI HAT
pulls ~11 W, and if the input never resumes, the deck runs the pack flat while
apparently plugged in.

## Open design decision: Python environments

Goal is per-project isolation, no dependency hell.

The constraint that shapes this: **`python3-gi`, `python3-libcamera`, and
`python3-picamera2` cannot be pip-installed.** They're GObject-introspection
typelibs and distro-built bindings tied to the system libcamera. A plain
`python3 -m venv` therefore produces an environment where the camera and the
indicator simply cannot import their core dependency.

Proposed approach: one venv per peripheral directory, each created with
`--system-site-packages`, so distro bindings remain visible while pip-installed
extras (numpy, opencv, HailoRT Python bindings) stay isolated per project. Hailo
is the one that most needs this, since its Python bindings get built from source
against Python 3.14.

Still to confirm: the venv package name on Python 3.14 (`python3-venv` vs
`python3.14-venv`), and whether Picamera2 tolerates `--system-site-packages`
cleanly in practice. Not yet implemented.
