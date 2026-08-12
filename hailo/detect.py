#!/usr/bin/env python3
"""Live object detection: Camera Module 3 -> Hailo-8 -> boxes.

    python3 detect.py                       # preview window on the deck's screen
    python3 detect.py --stream 8000         # MJPEG over HTTP, watch from a phone
    python3 detect.py --still out.jpg       # headless: one annotated frame
    python3 detect.py --classes person cat  # only these COCO classes

Run with the hailo venv so hailo_platform is importable:
    .venv/bin/python detect.py

The model does NMS on-chip: yolov8s.hef's output is HAILO_NMS_BY_CLASS, i.e. a
list of 80 arrays (one per COCO class), each (N, 5) of
[y_min, x_min, y_max, x_max, score] normalised to the 640x640 network input.
Decoding, thresholding and NMS all happen on the accelerator, so the CPU only
does letterboxing and drawing.
"""

from __future__ import annotations

import argparse
import io
import socket
import sys
import threading
import time
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image, ImageDraw

from hailo_platform import (
    HEF,
    ConfigureParams,
    FormatType,
    HailoStreamInterface,
    InferVStreams,
    InputVStreamParams,
    OutputVStreamParams,
    VDevice,
)
from picamera2 import Picamera2, Preview

NETWORK_SIZE = 640
PAD_VALUE = 114  # YOLO's letterbox grey

COCO_CLASSES = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck",
    "boat", "traffic light", "fire hydrant", "stop sign", "parking meter", "bench",
    "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra",
    "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
    "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove",
    "skateboard", "surfboard", "tennis racket", "bottle", "wine glass", "cup",
    "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
    "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
    "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy bear",
    "hair drier", "toothbrush",
]

PALETTE = [
    (230, 159, 0), (86, 180, 233), (0, 158, 115), (240, 228, 66),
    (0, 114, 178), (213, 94, 0), (204, 121, 167), (255, 255, 255),
]
# Anything in here gets drawn in a hard-to-miss colour.
HIGHLIGHT = {"cat", "dog", "person"}
HIGHLIGHT_COLOUR = (213, 94, 0)


class Detection:
    __slots__ = ("label", "score", "box")

    def __init__(self, label: str, score: float, box: tuple[int, int, int, int]):
        self.label = label
        self.score = score
        self.box = box


def letterbox(frame: np.ndarray) -> tuple[np.ndarray, float, int, int]:
    """Scale into a NETWORK_SIZE square preserving aspect ratio.

    Squashing 16:9 into a square would distort every object and cost accuracy,
    so we pad the way YOLO's own preprocessing does, then map boxes back.
    """
    height, width = frame.shape[:2]
    scale = min(NETWORK_SIZE / width, NETWORK_SIZE / height)
    new_w, new_h = int(round(width * scale)), int(round(height * scale))

    resized = np.asarray(Image.fromarray(frame).resize((new_w, new_h), Image.BILINEAR))
    canvas = np.full((NETWORK_SIZE, NETWORK_SIZE, 3), PAD_VALUE, dtype=np.uint8)
    pad_x, pad_y = (NETWORK_SIZE - new_w) // 2, (NETWORK_SIZE - new_h) // 2
    canvas[pad_y:pad_y + new_h, pad_x:pad_x + new_w] = resized
    return canvas, scale, pad_x, pad_y


def decode(raw, scale, pad_x, pad_y, frame_shape, threshold, wanted) -> list[Detection]:
    height, width = frame_shape[:2]
    detections: list[Detection] = []

    for class_id, boxes in enumerate(raw):
        arr = np.asarray(boxes)
        if arr.size == 0:
            continue
        label = COCO_CLASSES[class_id] if class_id < len(COCO_CLASSES) else str(class_id)
        if wanted and label not in wanted:
            continue

        for y1, x1, y2, x2, score in arr:
            if score < threshold:
                continue
            px1 = (x1 * NETWORK_SIZE - pad_x) / scale
            px2 = (x2 * NETWORK_SIZE - pad_x) / scale
            py1 = (y1 * NETWORK_SIZE - pad_y) / scale
            py2 = (y2 * NETWORK_SIZE - pad_y) / scale
            detections.append(Detection(label, float(score), (
                max(0, min(width - 1, int(px1))),
                max(0, min(height - 1, int(py1))),
                max(0, min(width - 1, int(px2))),
                max(0, min(height - 1, int(py2))),
            )))
    return detections


def colour_for(label: str) -> tuple[int, int, int]:
    if label in HIGHLIGHT:
        return HIGHLIGHT_COLOUR
    index = COCO_CLASSES.index(label) if label in COCO_CLASSES else 0
    return PALETTE[index % len(PALETTE)]


def draw(image: Image.Image, detections: list[Detection], status: str | None = None) -> None:
    canvas = ImageDraw.Draw(image)
    for det in detections:
        colour = colour_for(det.label)
        width = 5 if det.label in HIGHLIGHT else 3
        x1, y1, x2, y2 = det.box
        canvas.rectangle([x1, y1, x2, y2], outline=colour, width=width)
        caption = f"{det.label} {det.score:.0%}"
        box = canvas.textbbox((x1, y1), caption)
        canvas.rectangle([box[0] - 2, box[1] - 2, box[2] + 2, box[3] + 2], fill=colour)
        canvas.text((x1, y1), caption, fill=(0, 0, 0))

    if status:
        box = canvas.textbbox((8, 8), status)
        canvas.rectangle([box[0] - 4, box[1] - 4, box[2] + 4, box[3] + 4], fill=(0, 0, 0))
        canvas.text((8, 8), status, fill=(255, 255, 255))


class Detector:
    """Configured network group with a persistent inference pipeline.

    The activation and the InferVStreams pipeline are opened ONCE and kept open.
    Re-entering them per frame (the obvious way to write this) costs tens of
    milliseconds each time and dominates the runtime -- the accelerator itself
    does yolov8s in ~6 ms.
    """

    def __init__(self, hef_path: str):
        self._stack = ExitStack()
        self._hef = HEF(hef_path)
        self._device = VDevice()
        params = ConfigureParams.create_from_hef(
            self._hef, interface=HailoStreamInterface.PCIe
        )
        self._group = self._device.configure(self._hef, params)[0]
        self._input_name = self._hef.get_input_vstream_infos()[0].name

        in_params = InputVStreamParams.make(self._group, format_type=FormatType.UINT8)
        out_params = OutputVStreamParams.make(self._group, format_type=FormatType.FLOAT32)

        self._stack.enter_context(self._group.activate(self._group.create_params()))
        self._pipe = self._stack.enter_context(
            InferVStreams(self._group, in_params, out_params)
        )

    def infer(self, square: np.ndarray):
        results = self._pipe.infer({self._input_name: np.expand_dims(square, axis=0)})
        return next(iter(results.values()))[0]

    def close(self) -> None:
        self._stack.close()
        self._device.release()


def open_camera(width: int, height: int) -> Picamera2:
    cam = Picamera2()
    # Picamera2's "RGB888" is B,G,R in memory; we reverse channels after capture
    # so the network sees true RGB. Getting this backwards silently degrades
    # detection rather than failing outright.
    cam.configure(cam.create_preview_configuration(
        main={"size": (width, height), "format": "RGB888"}
    ))
    return cam


class FrameBuffer:
    """Latest annotated JPEG, shared between the capture loop and HTTP clients."""

    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._frame: bytes | None = None

    def publish(self, frame: bytes) -> None:
        with self._condition:
            self._frame = frame
            self._condition.notify_all()

    def wait(self, timeout: float = 5.0) -> bytes | None:
        with self._condition:
            self._condition.wait(timeout)
            return self._frame


def make_handler(buffer: FrameBuffer):
    class MJPEGHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):  # silence per-request logging
            pass

        def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
            if self.path in ("/", "/index.html"):
                page = (
                    b"<!doctype html><html><head><title>Cyberdeck</title>"
                    b"<meta name='viewport' content='width=device-width,initial-scale=1'>"
                    b"<style>body{margin:0;background:#111;display:flex;"
                    b"align-items:center;justify-content:center;height:100vh}"
                    b"img{max-width:100%;max-height:100vh}</style></head>"
                    b"<body><img src='/stream.mjpg'></body></html>"
                )
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)
                return

            if self.path != "/stream.mjpg":
                self.send_error(404)
                return

            self.send_response(200)
            self.send_header("Age", "0")
            self.send_header("Cache-Control", "no-cache, private")
            self.send_header("Pragma", "no-cache")
            self.send_header(
                "Content-Type", "multipart/x-mixed-replace; boundary=FRAME"
            )
            self.end_headers()
            try:
                while True:
                    frame = buffer.wait()
                    if frame is None:
                        continue
                    self.wfile.write(b"--FRAME\r\n")
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Content-Length", str(len(frame)))
                    self.end_headers()
                    self.wfile.write(frame)
                    self.wfile.write(b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass  # client navigated away

    return MJPEGHandler


def local_addresses(port: int) -> list[str]:
    urls = [f"http://localhost:{port}/"]
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 80))  # TEST-NET-1: routes without sending
        urls.append(f"http://{probe.getsockname()[0]}:{port}/")
        probe.close()
    except OSError:
        pass
    return urls


def capture_loop(detector, cam, args, on_frame) -> None:
    wanted = set(args.classes)
    frames = 0
    fps = 0.0
    window_start = time.perf_counter()
    seen: set[str] = set()

    while True:
        frame = cam.capture_array()[:, :, ::-1]
        square, scale, pad_x, pad_y = letterbox(frame)
        raw = detector.infer(square)
        detections = decode(raw, scale, pad_x, pad_y, frame.shape,
                            args.threshold, wanted)

        frames += 1
        elapsed = time.perf_counter() - window_start
        if elapsed >= 1.0:
            fps = frames / elapsed
            frames, window_start = 0, time.perf_counter()

            labels = {d.label for d in detections}
            new = labels - seen
            seen |= labels
            summary = ", ".join(sorted(labels)) or "-"
            print(f"{fps:5.1f} fps | {len(detections):2d} object(s): {summary}"
                  + (f"   <- NEW: {', '.join(sorted(new))}" if new else ""))

        on_frame(frame, detections, f"{fps:.1f} fps")


def run_stream(detector: Detector, args) -> int:
    buffer = FrameBuffer()
    server = ThreadingHTTPServer(("", args.stream), make_handler(buffer))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()

    print("Streaming — open any of these, Ctrl-C to stop:")
    for url in local_addresses(args.stream):
        print(f"  {url}")
    print()

    cam = open_camera(args.width, args.height)
    cam.start()

    def publish(frame, detections, status):
        image = Image.fromarray(frame)
        draw(image, detections, status)
        out = io.BytesIO()
        image.save(out, format="JPEG", quality=args.quality)
        buffer.publish(out.getvalue())

    try:
        capture_loop(detector, cam, args, publish)
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        cam.stop()
        cam.close()
        server.shutdown()
    return 0


def run_preview(detector: Detector, args) -> int:
    cam = open_camera(args.width, args.height)
    try:
        cam.start_preview(Preview.QTGL)
    except Exception:  # noqa: BLE001
        cam.start_preview(Preview.QT)
    cam.start()
    print("Live detection — Ctrl-C to stop.")

    def overlay(_frame, detections, status):
        # RGBA layer composited over the preview by the window itself.
        layer = Image.new("RGBA", (args.width, args.height), (0, 0, 0, 0))
        draw(layer, detections, status)
        cam.set_overlay(np.array(layer))

    try:
        capture_loop(detector, cam, args, overlay)
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        cam.stop()
        cam.stop_preview()
        cam.close()
    return 0


def run_still(detector: Detector, path: str, args) -> int:
    cam = open_camera(args.width, args.height)
    cam.start()
    time.sleep(2)  # let AE/AWB settle
    frame = cam.capture_array()[:, :, ::-1]
    cam.stop()
    cam.close()

    square, scale, pad_x, pad_y = letterbox(frame)
    started = time.perf_counter()
    raw = detector.infer(square)
    elapsed = time.perf_counter() - started

    detections = decode(raw, scale, pad_x, pad_y, frame.shape,
                        args.threshold, set(args.classes))
    image = Image.fromarray(frame)
    draw(image, detections)
    image.save(path)

    print(f"inference {elapsed * 1000:.1f} ms, {len(detections)} detection(s)")
    for det in sorted(detections, key=lambda d: -d.score):
        print(f"  {det.label:15s} {det.score:.0%}  {det.box}")
    print(f"wrote {path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hef", default="models/yolov8s.hef")
    parser.add_argument("--still", metavar="PATH", help="capture one annotated frame")
    parser.add_argument("--stream", type=int, metavar="PORT",
                        help="serve MJPEG over HTTP on this port")
    parser.add_argument("--threshold", type=float, default=0.4)
    parser.add_argument("--classes", nargs="*", default=[],
                        help="only report these COCO classes (default: all)")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--quality", type=int, default=80, help="MJPEG quality")
    args = parser.parse_args()

    unknown = [c for c in args.classes if c not in COCO_CLASSES]
    if unknown:
        print(f"Not COCO classes: {', '.join(unknown)}", file=sys.stderr)
        return 1

    detector = Detector(args.hef)
    try:
        if args.still:
            return run_still(detector, args.still, args)
        if args.stream:
            return run_stream(detector, args)
        return run_preview(detector, args)
    finally:
        detector.close()


if __name__ == "__main__":
    raise SystemExit(main())
