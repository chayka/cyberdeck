#!/usr/bin/env python3
"""Live preview / still capture for the Camera Module 3 Wide NoIR.

    python3 preview.py                # live preview window until Ctrl-C
    python3 preview.py --seconds 10   # preview for a fixed time
    python3 preview.py --still out.jpg  # headless: capture one frame and exit
    python3 preview.py --list         # show detected cameras and modes

Nothing here is Ubuntu-specific -- the point is that it doesn't need to be. The
imx708 and dw9807_vcm (autofocus) kernel drivers load automatically from
camera_auto_detect=1, and Ubuntu 26.04 carries libcamera 0.7.0, rpicam-apps and
python3-picamera2 in the archive. The Raspberry Pi apt repo is neither needed nor
safe here.

Preview backend note: this session is Wayland, but Qt runs through XWayland
(DISPLAY=:0), so the GL preview works. QTGL keeps scaling on the GPU; we fall
back to the software QT preview if GL is unavailable, e.g. over plain SSH.
"""

from __future__ import annotations

import argparse
import sys
import time

from picamera2 import Picamera2, Preview


def list_cameras() -> int:
    cameras = Picamera2.global_camera_info()
    if not cameras:
        print("No cameras detected.", file=sys.stderr)
        return 1
    for index, info in enumerate(cameras):
        print(f"[{index}] {info.get('Model')}  id={info.get('Id')}")
    with Picamera2() as cam:
        print("\nSensor modes:")
        for mode in cam.sensor_modes:
            print(f"  {mode['size']}  {mode['format']}  "
                  f"up to {mode.get('fps', '?')} fps")
    return 0


def capture_still(path: str) -> int:
    with Picamera2() as cam:
        cam.configure(cam.create_still_configuration())
        cam.start()
        # The first frames arrive before AE/AWB have settled; without this the
        # image is typically green and under-exposed.
        time.sleep(2)
        cam.capture_file(path)
        metadata = cam.capture_metadata()
    print(f"wrote {path}")
    lux = metadata.get("Lux")
    print(f"  exposure {metadata.get('ExposureTime')} us, "
          f"gain {metadata.get('AnalogueGain'):.2f}"
          + (f", lux {lux:.1f}" if isinstance(lux, (int, float)) else ""))
    focus = metadata.get("LensPosition")
    if focus is not None:
        print(f"  lens position {focus:.2f} (dw9807 autofocus)")
    return 0


def live_preview(seconds: float | None, size: tuple[int, int]) -> int:
    cam = Picamera2()
    cam.configure(cam.create_preview_configuration(main={"size": size}))

    for backend, label in ((Preview.QTGL, "QTGL"), (Preview.QT, "QT (software)")):
        try:
            cam.start_preview(backend)
            print(f"preview backend: {label}")
            break
        except Exception as exc:  # noqa: BLE001 - any backend failure is a fallback
            print(f"{label} unavailable ({exc})", file=sys.stderr)
    else:
        print("No preview backend available. Use --still on a headless session.",
              file=sys.stderr)
        return 1

    cam.start()
    print("Preview running — Ctrl-C to stop." if seconds is None
          else f"Preview running for {seconds}s.")
    try:
        if seconds is None:
            while True:
                time.sleep(0.5)
        else:
            time.sleep(seconds)
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        cam.stop()
        cam.stop_preview()
        cam.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true", help="list cameras and modes")
    parser.add_argument("--still", metavar="PATH", help="capture one frame, no window")
    parser.add_argument("--seconds", type=float, default=None,
                        help="preview duration (default: until Ctrl-C)")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    args = parser.parse_args()

    if args.list:
        return list_cameras()
    if args.still:
        return capture_still(args.still)
    return live_preview(args.seconds, (args.width, args.height))


if __name__ == "__main__":
    raise SystemExit(main())
