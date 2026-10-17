#!/usr/bin/env python3
"""Contact sheet of views aimed along a tracker output, to check by eye what it followed.

usage: track_viz.py lensA.mov lensB.mov calib.json track.txt start_seconds out.jpg [--every 20] [--fov 50]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from stitch_poc import camera_rays, stitch

ap = argparse.ArgumentParser()
for name in ("lens_a", "lens_b", "calib", "track"):
    ap.add_argument(name)
ap.add_argument("start", type=float)
ap.add_argument("out")
ap.add_argument("--every", type=int, default=20)
ap.add_argument("--fov", type=float, default=50)
a = ap.parse_args()

lenses = json.load(open(a.calib))["lenses"]
rows = [l.split() for l in open(a.track) if l[0].isdigit()]
track = {int(r[0]): (float(r[1]), float(r[2]), float(r[3])) for r in rows}
tiles = []
for i in sorted(k for k in track if k % a.every == 0):
    t = a.start + i * 1001 / 30000
    frames = []
    for src in (a.lens_a, a.lens_b):
        raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.4f}", "-i", src, "-frames:v", "1",
                              "-vf", "scale=1024:1024", "-f", "rawvideo", "-pix_fmt", "bgr24", "-"],
                             capture_output=True, check=True).stdout
        frames.append(np.frombuffer(raw, np.uint8).reshape(1024, 1024, 3))
    pan, tilt, conf = track[i]
    img, _ = stitch(frames, lenses, 320, rays=camera_rays(320, 240, pan, tilt, 0, a.fov, 0.0))
    img = img.copy()
    cv2.drawMarker(img, (160, 120), (0, 255, 255), cv2.MARKER_CROSS, 16, 1)
    cv2.putText(img, f"#{i} conf {conf:.2f}", (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)
    tiles.append(img)
while len(tiles) % 5:
    tiles.append(np.zeros_like(tiles[0]))
cv2.imwrite(a.out, np.vstack([np.hstack(tiles[i:i + 5]) for i in range(0, len(tiles), 5)]))
