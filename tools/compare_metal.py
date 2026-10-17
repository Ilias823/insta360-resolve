#!/usr/bin/env python3
"""Check the plugin's Metal stitch against the Python reference on a real clip.

Runs both on the same frame (scaled down for speed) and reports the difference,
for both buffer orientations the kernel supports.

usage: compare_metal.py clip.insv [--lens-width 1408] [--out-dir DIR]
Build the plugin test binary first:  make -C plugin test
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from insv_trailer import read_summary
from stitch_poc import camera_rays, decode, load_calibration, rot_x, rot_y, rot_z, stitch

TEST_BIN = Path(__file__).parent.parent / "plugin/build/test_plugin"
MAX_MEAN_DIFF = 0.5   # in 8-bit levels
MAX_P999_DIFF = 6.0

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("insv")
    ap.add_argument("--lens-width", type=int, default=1408)
    ap.add_argument("--out-dir", type=Path)
    a = ap.parse_args()

    lw = a.lens_width
    frames = [cv2.resize(decode(a.insv, t, 0), (lw, lw), interpolation=cv2.INTER_AREA) for t in (0, 1)]
    lenses = load_calibration(a.insv)
    w, h = 2 * lw, lw

    # (label, extra arguments for the test binary, rays for the Python reference)
    cases = [("stitched 360", [], None)]
    for pan, tilt, roll, fov, dist, aspect in ((0, 0, 0, 100, 0.0, 16 / 9), (135, -20, 10, 80, 0.0, 16 / 9),
                                               (-90, 35, -25, 120, 0.0, 9 / 16), (60, 10, 0, 150, 0.5, 16 / 9),
                                               (40, -90, 0, 300, 1.0, 1.0)):
        rays = camera_rays(w, h, pan, tilt, roll, fov, dist, aspect)
        cases.append((f"reframe pan {pan} tilt {tilt} roll {roll} fov {fov} distance {dist}",
                      [str(x) for x in (pan, tilt, roll, fov, dist, aspect)], rays))

    # Stabilisation turns every ray by a rotation (view to camera) before sampling the lenses.
    stab = rot_y(25.0) @ rot_x(-12.0) @ rot_z(8.0)
    stab_arg = ",".join(f"{v:.9f}" for v in stab.ravel())
    view = camera_rays(w, h, 30, 5, 0, 100, 0.25, 16 / 9)
    cases.append(("reframe, stabilised", [str(x) for x in (30, 5, 0, 100, 0.25, 16 / 9)] + [stab_arg],
                  (stab @ view.reshape(3, -1)).reshape(view.shape)))

    side_by_side = np.concatenate(frames, axis=1)[..., ::-1].astype(np.float32) / 255.0
    rgba = np.concatenate([side_by_side, np.ones((lw, 2 * lw, 1), np.float32)], axis=2)

    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "calib.json").write_text(json.dumps(read_summary(a.insv)))
        for n, (label, extra, rays) in enumerate(cases):
            reference, _ = stitch(frames, lenses, w, rays=rays)
            for flip in (0, 1):
                src = rgba[::-1] if flip else rgba
                np.ascontiguousarray(src).tofile(tmp / "in.raw")
                subprocess.run([str(TEST_BIN), "--stitch", str(tmp / "in.raw"), str(w), str(h),
                                str(tmp / "calib.json"), str(tmp / "out.raw"), str(flip)] + extra, check=True)
                out = np.fromfile(tmp / "out.raw", np.float32).reshape(h, w, 4)
                out = out[::-1] if flip else out
                metal = np.clip(out[..., 2::-1] * 255.0, 0, 255)
                diff = np.abs(metal - reference.astype(np.float32))
                mean, p999 = float(diff.mean()), float(np.percentile(diff, 99.9))
                ok = mean < MAX_MEAN_DIFF and p999 < MAX_P999_DIFF
                failed |= not ok
                print(f"{'ok  ' if ok else 'FAIL'}  {label}, flipY={flip}: mean diff {mean:.3f}, "
                      f"99.9th percentile {p999:.2f}, max {diff.max():.1f} (8-bit levels)")
            if a.out_dir:
                a.out_dir.mkdir(parents=True, exist_ok=True)
                cv2.imwrite(str(a.out_dir / f"metal_case{n}.jpg"), metal.astype(np.uint8))
                cv2.imwrite(str(a.out_dir / f"python_case{n}.jpg"), reference)
    sys.exit(1 if failed else 0)
