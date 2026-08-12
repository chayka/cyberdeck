#!/usr/bin/env python3
"""Live object detection: Camera Module 3 -> Hailo-8 -> boxes on screen.

    python3 detect.py                      # live preview with detection overlay
    python3 detect.py --still out.jpg      # headless: one annotated frame
    python3 detect.py --classes person cat # only show these COCO classes

Run it with the hailo venv so hailo_platform is importable:
    ../hailo/.venv/bin/python detect.py

The model does NMS on-chip: yolov8s.hef's output is HAILO_NMS_BY_CLASS, i.e. a
list of 80 arrays (one per COCO class), each (N, 5) of
[y_min, x_min, y_max, x_max, score] normalised to the 640x640 network input.
So there is no post-processing to implement here -- decoding, thresholding and
NMS all happen on the accelerator, which is why this stays cheap on the CPU.
"""

from __future__ import annotations

import argparse
import sys
import time

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
#: YOLO's letterbox padding colour.
PAD_VALUE = 114

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

# Distinct, colour-blind-friendly hues; index cycles per class.
PALETTE = [
    (230, 159, 0), (86, 180, 233), (0, 158, 115), (240, 228, 66),
    (0, 114, 178), (213, 94, 0), (204, 121, 167), (255, 255, 255),
]


class Detection:
    __slots__ = ("label", "score", "box")

    def __init__(self, label: str, score: float, box: tuple[int, int, int, int]):
        self.label = label
        self.score = score
        self.box = box  # (x1, y1, x2, y2) in source-frame pixels


def letterbox(frame: np.ndarray) -> tuple[np.ndarray, float, int, int]:
    """Scale `frame` into a NETWORK_SIZE square, preserving aspect ratio.

    Squashing a 16:9 frame into a square instead would distort every object and
    measurably cost accuracy, so we pad like YOLO's own preprocessing does.
    Returns the padded image plus the scale and offsets needed to map boxes back.
    """
    height, width = frame.shape[:2]
    scale = min(NETWORK_SIZE / width, NETWORK_SIZE / height)
    new_w, new_h = int(round(width * scale)), int(round(height * scale))

    resized = np.asarray(
        Image.fromarray(frame).resize((new_w, new_h), Image.BILINEAR)
    )
    canvas = np.full((NETWORK_SIZE, NETWORK_SIZE, 3), PAD_VALUE, dtype=np.uint8)
    pad_x, pad_y = (NETWORK_SIZE - new_w) // 2, (NETWORK_SIZE - new_h) // 2
    canvas[pad_y:pad_y + new_h, pad_x:pad_x + new_w] = resized
    return canvas, scale, pad_x, pad_y


def decode(raw, scale, pad_x, pad_y, frame_shape, threshold, wanted) -> list[Detection]:
    """Turn the on-chip NMS output into pixel-space detections."""
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
            # Normalised to the letterboxed square -> undo padding, undo scale.
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


def draw(image: Image.Image, detections: list[Detection]) -> None:
    canvas = ImageDraw.Draw(image)
    for det in detections:
        colour = PALETTE[COCO_CLASSES.index(det.label) % len(PALETTE)
                         if det.label in COCO_CLASSES else 0]
        x1, y1, x2, y2 = det.box
        canvas.rectangle([x1, y1, x2, y2], outline=colour, width=3)
        caption = f"{det.label} {det.score:.0%}"
        text_box = canvas.textbbox((x1, y1), caption)
        canvas.rectangle(
            [text_box[0] - 2, text_box[1] - 2, text_box[2] + 2, text_box[3] + 2],
            fill=colour,
        )
        canvas.text((x1, y1), caption, fill=(0, 0, 0))


class Detector:
    """Wraps the configured network group and its inference pipeline."""

    def __init__(self, hef_path: str):
        self._hef = HEF(hef_path)
        self._device = VDevice()
        params = ConfigureParams.create_from_hef(
            self._hef, interface=HailoStreamInterface.PCIe
        )
        self._group = self._device.configure(self._hef, params)[0]
        self._group_params = self._group.create_params()
        self._input_name = self._hef.get_input_vstream_infos()[0].name
        self._in_params = InputVStreamParams.make(self._group, format_type=FormatType.UINT8)
        self._out_params = OutputVStreamParams.make(self._group, format_type=FormatType.FLOAT32)

    def infer(self, square: np.ndarray):
        batch = np.expand_dims(square, axis=0)
        with self._group.activate(self._group_params):
            with InferVStreams(self._group, self._in_params, self._out_params) as pipe:
                results = pipe.infer({self._input_name: batch})
        # Single output, single batch element.
        return next(iter(results.values()))[0]

    def close(self) -> None:
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


def run_still(detector: Detector, path: str, args) -> int:
    cam = open_camera(args.width, args.height)
    cam.start()
    time.sleep(2)  # let AE/AWB settle
    frame = cam.capture_array()[:, :, ::-1]  # BGR -> RGB
    cam.stop()
    cam.close()

    square, scale, pad_x, pad_y = letterbox(frame)
    started = time.perf_counter()
    raw = detector.infer(square)
    elapsed = time.perf_counter() - started

    detections = decode(raw, scale, pad_x, pad_y, frame.shape, args.threshold, set(args.classes))
    image = Image.fromarray(frame)
    draw(image, detections)
    image.save(path)

    print(f"inference {elapsed * 1000:.1f} ms, {len(detections)} detection(s)")
    for det in sorted(detections, key=lambda d: -d.score):
        print(f"  {det.label:15s} {det.score:.0%}  {det.box}")
    print(f"wrote {path}")
    return 0


def run_live(detector: Detector, args) -> int:
    cam = open_camera(args.width, args.height)
    try:
        cam.start_preview(Preview.QTGL)
    except Exception:  # noqa: BLE001
        cam.start_preview(Preview.QT)
    cam.start()

    print("Live detection — Ctrl-C to stop.")
    wanted = set(args.classes)
    frames = 0
    started = time.perf_counter()
    try:
        while True:
            frame = cam.capture_array()[:, :, ::-1]
            square, scale, pad_x, pad_y = letterbox(frame)
            raw = detector.infer(square)
            detections = decode(raw, scale, pad_x, pad_y, frame.shape,
                                args.threshold, wanted)

            # Preview overlays are RGBA composited by the preview window.
            overlay = Image.new("RGBA", (args.width, args.height), (0, 0, 0, 0))
            draw(overlay, detections)
            cam.set_overlay(np.array(overlay))

            frames += 1
            if frames % 30 == 0:
                fps = frames / (time.perf_counter() - started)
                names = ", ".join(sorted({d.label for d in detections})) or "-"
                print(f"{fps:5.1f} fps | {len(detections)} object(s): {names}")
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        cam.stop()
        cam.stop_preview()
        cam.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hef", default="models/yolov8s.hef")
    parser.add_argument("--still", metavar="PATH", help="capture one annotated frame")
    parser.add_argument("--threshold", type=float, default=0.4)
    parser.add_argument("--classes", nargs="*", default=[],
                        help="only report these COCO classes (default: all)")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    args = parser.parse_args()

    unknown = [c for c in args.classes if c not in COCO_CLASSES]
    if unknown:
        print(f"Not COCO classes: {', '.join(unknown)}", file=sys.stderr)
        return 1

    detector = Detector(args.hef)
    try:
        if args.still:
            return run_still(detector, args.still, args)
        return run_live(detector, args)
    finally:
        detector.close()


if __name__ == "__main__":
    raise SystemExit(main())
