#!/usr/bin/env python3
"""Refine a camera's calibration so that the two lenses line up at the stitch seam.

The factory calibration, read the way the plugin reads it, leaves lens B up to about 1 degree
off at the seam (on the X5 this project was developed with: ~20 px in a 3840 lens image). The
error is the same in every frame, so it can be measured from footage: at points around the seam,
find the shift of lens B (across the seam, as a stitch distance, and along it) that matches lens
A best, take the median over frames spread through the clip, and fit lens B's yaw, pitch and
image centre to those shifts. Real parallax varies from frame to frame and drops out in the median.

The corrected values replace "calibration_raw" and "lenses" in the clip's .json; the factory
values are kept as "calibration_factory". Running it again starts from the factory values.

This is the numpy reference. tools/ingest.py runs the same algorithm through the C++ helper
plugin/src/SeamRefine.cpp, which needs no Python packages; --compare checks the two agree.

usage: refine_seam.py clip.json lensA.mov lensB.mov [--frames 10] [--dry-run] [--compare]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from ingest import REFINE_SIZE as WORK_W, adjusted_lenses as adjusted, apply_refinement, measure_seam
from ingest import read_frame as read_raw_frame, refine_times
from insv_trailer import SENSOR_W
from stitch_poc import lens_offset, rot_z, warp

COLUMNS, ROWS, BINS = 512, 24, 32
BAND_DEG = 4.0
INV_DISTANCES = np.linspace(-1.5, 2.5, 33)   # across the seam; below 0 is a calibration error, not parallax
ALONG_DEG = np.linspace(-1.0, 1.0, 21)       # along the seam
# Largest differences accepted between this reference and the SeamRefine helper (--compare).
COMPARE_TOLERANCE = {"yaw": 0.01, "pitch": 0.01, "cx": 0.5, "cy": 0.5}


def read_frame(path, seconds):
    return np.frombuffer(read_raw_frame(path, seconds, "bgr24"), np.uint8).reshape(WORK_W, WORK_W, 3)


def seam_rays():
    phi = (np.arange(COLUMNS) + 0.5) / COLUMNS * 2 * np.pi
    z = np.sin(np.radians(BAND_DEG)) * ((np.arange(ROWS) + 0.5) / ROWS * 2 - 1)
    p, z = np.meshgrid(phi, z)
    c = np.sqrt(1 - z * z)
    return np.stack([c * np.cos(p), c * np.sin(p), z])


def measure(frames, lenses):
    """Best (1/distance, along-seam degrees) per bin and frame: arrays of shape (frames, BINS)."""
    rays = seam_rays()
    half = (lens_offset(lenses) / 2)[:, None, None]
    per_bin = COLUMNS // BINS
    q_best, along_best = [], []
    for frame in frames:
        cost = np.zeros((len(INV_DISTANCES), len(ALONG_DEG), BINS))
        for i, q in enumerate(INV_DISTANCES):
            ray_a = rays + half * q
            ray_a /= np.linalg.norm(ray_a, axis=0)
            ray_b = rays - half * q
            ray_b /= np.linalg.norm(ray_b, axis=0)
            (a, _), (valid_a, _) = warp(frame, lenses, (ray_a, ray_a))
            luma_a = a.mean(2)
            for j, along in enumerate(ALONG_DEG):
                turned = (rot_z(along) @ ray_b.reshape(3, -1)).reshape(ray_b.shape)
                (_, b), (_, valid_b) = warp(frame, lenses, (turned, turned))
                ok = valid_a & valid_b
                diff = np.abs(luma_a - b.mean(2)) * ok
                cost[i, j] = (np.add.reduceat(diff.sum(0), np.arange(0, COLUMNS, per_bin)) /
                              np.maximum(np.add.reduceat(ok.sum(0), np.arange(0, COLUMNS, per_bin)), 1))
        i, j = np.unravel_index(cost.reshape(-1, BINS).argmin(0), cost.shape[:2])
        q_best.append(INV_DISTANCES[i])
        along_best.append(ALONG_DEG[j])
    return np.array(q_best), np.array(along_best)


def project_b(lenses, rays):
    """Lens B pixel positions (3840-wide tile) for rig rays (3, n), as the plugin computes them."""
    from stitch_poc import CROP_W, lens_rotation, project
    local = lens_rotation(lenses[1], 1, 0).T @ rays
    # Double precision: in float32 the finite-difference Jacobian in fit() is too noisy to converge.
    u, v, _ = project(lenses[1], local[:, :, None], 3840, CROP_W, SENSOR_W, np.float64)
    return np.stack([u[:, 0], v[:, 0]])


def fit(lenses, q_best, along_best):
    """Fits lens B (yaw, pitch, cx, cy) to the median shifts; returns the fit and residuals in px."""
    q_med, along_med = np.median(q_best, 0), np.median(along_best, 0)
    # Bins where the frames disagree (moving people close to the camera) count less.
    weight = 1 / (0.05 + np.median(np.abs(along_best - along_med), 0) + 0.3 * np.median(np.abs(q_best - q_med), 0))
    phi = (np.arange(BINS) + 0.5) / BINS * 2 * np.pi
    seam = np.stack([np.cos(phi), np.sin(phi), np.zeros(BINS)])
    half = (lens_offset(lenses) / 2)[:, None]

    def target(q0):
        # Where lens B should be sampled: the measured shift, less a parallax common to the whole seam.
        rays = seam - half * (q_med - q0)
        rays /= np.linalg.norm(rays, axis=0)
        return project_b(lenses, np.stack([rot_z(a) @ rays[:, k] for k, a in enumerate(along_med)], 1))

    def model(x):
        rays = seam - half * x[4]
        return project_b(adjusted(lenses, x), rays / np.linalg.norm(rays, axis=0))

    def residual(x):
        return ((model(x) - target(x[4])) * np.sqrt(weight)).ravel()

    x = np.zeros(5)
    for _ in range(50):
        r = residual(x)
        jac = np.stack([(residual(x + e) - r) / 1e-4 for e in np.eye(5) * 1e-4], 1)
        step = np.linalg.lstsq(jac, -r, rcond=None)[0]
        x += step
        if np.abs(step).max() < 1e-6:
            break
    before = np.hypot(*(model(np.r_[0, 0, 0, 0, x[4]]) - target(x[4])))
    after = np.hypot(*(model(x) - target(x[4])))
    return x, before, after


def compare(x, before, after, helper_fit):
    """Prints both fits side by side; returns True if they agree within COMPARE_TOLERANCE."""
    ok = True
    for k, name in enumerate(("yaw", "pitch", "cx", "cy")):
        diff = abs(helper_fit[name] - x[k])
        ok &= diff <= COMPARE_TOLERANCE[name]
        print(f"  {name:5s} reference {x[k]:+8.3f}  helper {helper_fit[name]:+8.3f}  diff {diff:.3f}"
              f"{'' if diff <= COMPARE_TOLERANCE[name] else '  TOO LARGE'}")
    print(f"  misalignment reference {before:.1f} -> {after:.1f} px, "
          f"helper {helper_fit['misalignment_px'][0]:.1f} -> {helper_fit['misalignment_px'][1]:.1f} px")
    print("helper agrees with the reference" if ok else "helper DISAGREES with the reference")
    return ok


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("calibration", type=Path)
    ap.add_argument("lens_a", type=Path)
    ap.add_argument("lens_b", type=Path)
    ap.add_argument("--frames", type=int, default=10)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--compare", action="store_true",
                    help="also run the SeamRefine helper (plugin build) and check it agrees; implies --dry-run")
    a = ap.parse_args()

    info = json.loads(a.calibration.read_text())
    factory_raw = info.get("calibration_factory", info["calibration_raw"])
    factory_lenses = info.get("lenses_factory", info["lenses"])

    frames = [[read_frame(a.lens_a, t), read_frame(a.lens_b, t)] for t in refine_times(a.lens_a, a.lens_b, a.frames)]
    q_best, along_best = measure(frames, factory_lenses)
    x, before, after = fit(factory_lenses, q_best, along_best)
    before, after = float(np.median(before)), float(np.median(after))

    print(f"lens B: yaw {x[0]:+.3f} deg, pitch {x[1]:+.3f} deg, centre {x[2]:+.1f}, {x[3]:+.1f} sensor px")
    print(f"seam misalignment (3840 px lens image), median over the seam: {before:.1f} px -> {after:.1f} px")
    if a.compare:
        sys.exit(0 if compare(x, before, after, measure_seam(a.lens_a, a.lens_b, factory_raw, a.frames)) else 1)
    if after > 0.5 * before:
        print("the fit does not explain the misalignment well; calibration left unchanged")
        sys.exit(1)
    if a.dry_run:
        sys.exit(0)

    apply_refinement(info, x, before, after, a.frames)
    a.calibration.write_text(json.dumps(info, indent=2))
    print(f"wrote {a.calibration}")
