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
| Top-bar indicator | **Working**, running as `cyberdeck-ups.service`, registered with GNOME. |
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

1. Live preview mode of `detect.py` has never been eyeballed (needs a human at the
   screen). `--still` and `--stream` are both verified.
2. **Reboot test outstanding** — everything is configured to persist, but that is
   a claim, not a result.
3. Streaming runs at ~10.7 fps, limited by CPU-side letterboxing, PIL drawing and
   JPEG encoding — not by the accelerator, which does yolov8s at 174 fps. Hardware
   JPEG encoding via Picamera2's encoder would be the real fix.
4. Possible hardware issue: the UPS showed input present at 15.13 V but ~0.01 A
   while the pack discharged at 0.65 A. May just be recharge hysteresis at 96%; if
   it persists, the deck drains the battery while apparently plugged in.
5. Optional: a UPower-compatible daemon would put the UPS in GNOME's real battery
   menu (low-battery warnings, suspend policy) instead of a custom indicator.
6. Hailo model compilation (Dataflow Compiler) only matters if custom models are
   ever needed; it pins Python 3.10/3.11 and belongs in a container.

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
