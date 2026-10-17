#!/usr/bin/env python3
"""Proof-of-concept stitch: one frame of an X5 .insv -> equirectangular image.

CPU reference for the future Metal shader. Lens model and calibration layout follow
the MIT-licensed insv-stitch project (github.com/BenjaminHenriksson/insv-stitch).

usage: stitch_poc.py clip.insv out.jpg [--width 3840] [--frame 0] [--sweep]
"""
import argparse
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from insv_trailer import SENSOR_W, read_summary

CROP_W = 5312     # focal lengths are relative to this crop width (best seam match in sweep)
BLEND_DEG = 4.0   # default Seam Blend Width (full width, degrees)


def load_calibration(path):
    return read_summary(path)["lenses"]


def rot_y(deg):
    a = np.radians(deg); c, s = np.cos(a), np.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rot_x(deg):
    a = np.radians(deg); c, s = np.cos(a), np.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def rot_z(deg):
    a = np.radians(deg); c, s = np.cos(a), np.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def lens_rotation(lens, index, roll_sign):
    r = rot_y(lens["yaw"]) @ rot_x(lens["pitch"]) @ rot_z(roll_sign * (lens["roll"] - 90.0))
    return rot_y(180.0) @ r if index == 1 else r


def equirect_rays(w, h):
    u, v = np.meshgrid(np.arange(w) + 0.5, np.arange(h) + 0.5)
    lon = u / w * 2 * np.pi - np.pi
    lat = np.pi / 2 - v / h * np.pi
    return np.stack([np.cos(lat) * np.sin(lon), -np.sin(lat), np.cos(lat) * np.cos(lon)])


def camera_rays(w, h, pan, tilt, roll, fov, distance=0.0, aspect=None):
    """Rays for the reframe camera. Angles in degrees; fov spans the longer side.

    The camera sits `distance` behind the sphere centre: 0 is a linear lens, 1 stereographic.
    """
    aspect = aspect or w / h
    d = min(max(distance, (fov - 100.0) / 160.0, 0.0), 1.0)   # wide views curve automatically
    fov = min(fov, min(2 * np.degrees(np.arccos(-d)) - 20.0, 340.0))
    half = np.radians(fov) / 2
    plane = np.sin(half) / (np.cos(half) + d)
    u, v = np.meshgrid((np.arange(w) + 0.5) / w * 2 - 1, (np.arange(h) + 0.5) / h * 2 - 1)
    sx, sy = (1.0, 1.0 / aspect) if aspect >= 1 else (aspect, 1.0)
    px, py = u * plane * sx, v * plane * sy
    r2 = px * px + py * py
    t = (d + np.sqrt(np.maximum(1 + r2 * (1 - d * d), 0))) / (r2 + 1)
    cam = np.stack([px * t, py * t, t - d])
    # rot_x here tips +z towards -y (up) for positive angles, matching the plugin's tilt.
    rot = rot_y(pan) @ rot_x(tilt) @ rot_z(roll)
    return (rot @ cam.reshape(3, -1)).reshape(3, h, w)


def project(lens, rays, video_w, f_div, c_div, dtype=np.float32):
    """Rays in the lens frame -> source pixel coordinates (MEI model); float32 suits cv2.remap."""
    x, y, z = rays
    den = z + lens["xi"]
    ok = den > 1e-6
    den = np.where(ok, den, 1.0)
    x, y = x / den, y / den
    k1, k2, k3, k4, _, p1, p2, s1, s2, s3, s4 = lens["d"][:11]
    r2 = x * x + y * y
    r4 = r2 * r2
    rad = 1 + k1 * r2 + k2 * r4 + k3 * r2 * r4 + k4 * r4 * r4
    xd = x * rad + 2 * p1 * x * y + p2 * (r2 + 2 * x * x) + s1 * r2 + s2 * r4
    yd = y * rad + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y + s3 * r2 + s4 * r4
    fs, cs = video_w / f_div, video_w / c_div
    u = lens["fx"] * fs * xd + lens["cx"] * cs
    v = lens["fy"] * fs * yd + lens["cy"] * cs
    ok &= np.hypot(u - video_w / 2, v - video_w / 2) < video_w / 2 * 0.975
    return u.astype(dtype), v.astype(dtype), ok


# Seam analysis, mirrored by SeamKernel in plugin/src/MetalKernel.mm: the stitch distance and the
# colour difference between the lenses, measured on a grid of rays around the seam each frame.
SEAM_COLUMNS = 256      # samples around the seam ...
SEAM_ROWS = 32          # ... and across it, within +-SEAM_BAND_DEG (the lenses overlap about +-6)
SEAM_BAND_DEG = 4.0
SEAM_BINS = 64          # table entries around the seam
SEAM_FADE_DEG = 30.0    # the corrections fade out between the band edge and this distance from the seam
GAIN_SIGMA_DEG = 15.0   # smoothing of the gain along the seam
GAIN_PRIOR = 64.0       # pulls bins with few usable samples towards the global gain
DEPTH_STEPS = 12        # candidate stitch distances, evenly spaced in 1 / distance ...
MAX_INV_DISTANCE = 2.5  # ... from infinity to 0.4 m
DEPTH_SIGMA_DEG = 12.0  # the match of each candidate is pooled over this much of the seam
DEPTH_PRIOR = 0.05      # cost per 1/m away from DEFAULT_DISTANCE: keeps flat areas put and frames steady
DEFAULT_DISTANCE = 2.0  # metres; also the plugin's Stitch Distance default
DEPTH_TABLE_SIGMA_DEG = 4.0


def lens_offset(lenses):
    """Position of lens B relative to lens A in the rig frame, metres."""
    return np.asarray(lenses[1].get("t", (0.0, 0.0, 0.0)), dtype=np.float64)


def lens_rays(rays, offset, inv_distance):
    """Directions from each lens to the point inv_distance (1/m, scalar or per ray) away along rays.

    The rig centre sits halfway between the lenses, so both lenses move by half the parallax.
    """
    q = np.asarray(inv_distance, dtype=np.float64)
    half = (offset / 2).reshape(3, *([1] * (rays.ndim - 1)))
    out = []
    for sign in (1.0, -1.0):
        r = rays + sign * half * q
        out.append(r / np.linalg.norm(r, axis=0))
    return out


def warp(frames, lenses, rays, f_div=CROP_W, c_div=SENSOR_W, roll_sign=0):
    """Samples both lenses along rig-space rays (3, h, w), or a pair of ray sets, one per lens.

    Returns warped images and validity masks.
    """
    per_lens = rays if isinstance(rays, (list, tuple)) else (rays, rays)
    warped, valid = [], []
    for i, (img, lens, r) in enumerate(zip(frames, lenses, per_lens)):
        h, w = r.shape[1:]
        local = (lens_rotation(lens, i, roll_sign).T @ r.reshape(3, -1)).reshape(3, h, w)
        u, v, ok = project(lens, local, img.shape[1], f_div, c_div)
        warped.append(cv2.remap(img, u, v, cv2.INTER_LINEAR).astype(np.float32))
        valid.append(ok)
    return warped, valid


def wrapped(d):
    return d - 2 * np.pi * np.rint(d / (2 * np.pi))


def seam_tables(frames, lenses, auto_distance=True, inv_distance=1 / DEFAULT_DISTANCE,
                f_div=CROP_W, c_div=SENSOR_W, roll_sign=0):
    """Gain lens A / lens B per channel and 1 / stitch distance, as tables around the seam.

    Returns (gain table (bins, 3), global gain (3,), inverse distance table (bins,)).
    """
    phi = (np.arange(SEAM_COLUMNS) + 0.5) / SEAM_COLUMNS * 2 * np.pi
    z = np.sin(np.radians(SEAM_BAND_DEG)) * ((np.arange(SEAM_ROWS) + 0.5) / SEAM_ROWS * 2 - 1)
    p, z = np.meshgrid(phi, z)
    c = np.sqrt(1 - z * z)
    rays = np.stack([c * np.cos(p), c * np.sin(p), z])
    offset = lens_offset(lenses)
    dphi = wrapped(phi[None, :] - phi[:, None])     # columns x columns

    # 1. Stitch distance per column: the candidate where the lenses agree best across the seam,
    #    pooled along the seam, with a small pull towards the default distance.
    if auto_distance:
        steps = np.arange(DEPTH_STEPS) * MAX_INV_DISTANCE / (DEPTH_STEPS - 1)
        cost_sum, cost_n = [], []
        for q in steps:
            (a, b), (va, vb) = warp(frames, lenses, lens_rays(rays, offset, q), f_div, c_div, roll_sign)
            ok = va & vb
            diff = np.abs(a.mean(2) - b.mean(2)) / 255.0
            cost_sum.append((diff * ok).sum(0))
            cost_n.append(ok.sum(0).astype(np.float64))
        pool = np.exp(-0.5 * (dphi / np.radians(DEPTH_SIGMA_DEG)) ** 2)
        cost = (pool @ np.array(cost_sum).T) / np.maximum(pool @ np.array(cost_n).T, 1e-6)   # columns x steps
        cost += DEPTH_PRIOR * np.abs(steps[None, :] - 1 / DEFAULT_DISTANCE)
        k = np.argmin(cost, axis=1)
        col_q = steps[k].copy()
        inner = (k > 0) & (k < DEPTH_STEPS - 1)
        idx = np.arange(SEAM_COLUMNS)[inner]
        lo, mid, hi = cost[idx, k[inner] - 1], cost[idx, k[inner]], cost[idx, k[inner] + 1]
        curve = lo - 2 * mid + hi
        shift = np.where(curve > 1e-9, np.clip(0.5 * (lo - hi) / np.maximum(curve, 1e-9), -0.5, 0.5), 0.0)
        col_q[inner] += shift * steps[1]
    else:
        col_q = np.full(SEAM_COLUMNS, float(inv_distance))

    # 2. Colour of both lenses at that distance. Samples that are near black, clipped, or too
    #    different in brightness (the lenses see different objects) are left out.
    (a, b), (va, vb) = warp(frames, lenses, lens_rays(rays, offset, col_q[None, :]), f_div, c_div, roll_sign)
    a, b = a / 255.0, b / 255.0
    la, lb = a.mean(2), b.mean(2)
    use = va & vb & (la > 0.02) & (lb > 0.02) & (la < 0.95) & (lb < 0.95) & (la < 2 * lb) & (lb < 2 * la)
    col_a = (a * use[..., None]).sum(0)         # (columns, 3)
    col_b = (b * use[..., None]).sum(0)
    n = use.sum()

    centre = (np.arange(SEAM_BINS) + 0.5) / SEAM_BINS * 2 * np.pi
    d = wrapped(phi[None, :] - centre[:, None])     # bins x columns
    wq = np.exp(-0.5 * (d / np.radians(DEPTH_TABLE_SIGMA_DEG)) ** 2)
    q_table = (wq @ col_q) / wq.sum(1)
    if n == 0:
        return np.ones((SEAM_BINS, 3)), np.ones(3), q_table
    mean_a, mean_b = col_a.sum(0) / n, col_b.sum(0) / n
    wgt = np.exp(-0.5 * (d / np.radians(GAIN_SIGMA_DEG)) ** 2)
    sum_a = wgt @ col_a + GAIN_PRIOR * mean_a
    sum_b = wgt @ col_b + GAIN_PRIOR * mean_b
    table = np.clip(sum_a / np.maximum(sum_b, 1e-6), 0.5, 2.0)
    overall = np.clip(mean_a / np.maximum(mean_b, 1e-6), 0.5, 2.0)
    return table, overall, q_table


def table_at(rays, table):
    """Table value for each ray, interpolated around the seam."""
    f = (np.arctan2(rays[1], rays[0]) / (2 * np.pi) * SEAM_BINS - 0.5) % SEAM_BINS
    k0 = np.floor(f).astype(int)
    t = f - k0
    if table.ndim == 2:
        t = t[..., None]
    return table[k0 % SEAM_BINS] * (1 - t) + table[(k0 + 1) % SEAM_BINS] * t


def near_seam(rays):
    """1 within the measured band around the seam, fading to 0 at SEAM_FADE_DEG from it."""
    lo, hi = np.sin(np.radians(SEAM_BAND_DEG)), np.sin(np.radians(SEAM_FADE_DEG))
    return np.clip((hi - np.abs(rays[2])) / (hi - lo), 0, 1)


def stitch(frames, lenses, w, f_div=CROP_W, c_div=SENSOR_W, roll_sign=0, blend_deg=BLEND_DEG / 2, rays=None,
           gain_match=True, auto_distance=True, distance=DEFAULT_DISTANCE):
    """Equirectangular by default; pass rays from camera_rays() for a reframed view."""
    if rays is None:
        rays = equirect_rays(w, w // 2)
    table, overall, q_table = seam_tables(frames, lenses, auto_distance, 1 / distance, f_div, c_div, roll_sign)
    near = near_seam(rays)
    q = table_at(rays, q_table) * near
    warped, valid = warp(frames, lenses, lens_rays(rays, lens_offset(lenses), q), f_div, c_div, roll_sign)
    if gain_match:
        # Meet in the middle: lens A down by sqrt(gain), lens B up by the same factor.
        gain = overall + (table_at(rays, table) - overall) * near[..., None]
        root = np.sqrt(gain).astype(np.float32)
        warped = [warped[0] / root, warped[1] * root]
    band = np.sin(np.radians(blend_deg))
    wf = np.clip((rays[2] + band) / (2 * band), 0, 1)
    wf = wf * wf * (3 - 2 * wf)     # smoothstep: no kink in brightness at the band edges
    wf = np.where(valid[1], wf, 1.0) * valid[0]
    wb = np.where(valid[0], 1 - wf, 1.0) * valid[1]
    out = (warped[0] * wf[..., None] + warped[1] * wb[..., None]) / np.maximum(wf + wb, 1e-6)[..., None]
    both = valid[0] & valid[1] & (np.abs(rays[2]) < np.sin(np.radians(3.0)))
    ga = cv2.cvtColor(warped[0], cv2.COLOR_BGR2GRAY)
    gb = cv2.cvtColor(warped[1], cv2.COLOR_BGR2GRAY)
    seam_err = float(np.abs(ga[both] - gb[both]).mean()) if both.any() else 0.0
    return np.clip(out + 0.5, 0, 255).astype(np.uint8), seam_err   # rounded, not truncated


def decode(path, track, frame):
    tmp = Path(path).with_suffix(f".lens{track}.png")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(path), "-map", f"0:{track}",
                    "-vf", f"select=eq(n\\,{frame})", "-frames:v", "1", str(tmp)], check=True)
    img = cv2.imread(str(tmp))
    tmp.unlink()
    return img


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("insv"); ap.add_argument("out")
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--frame", type=int, default=0)
    ap.add_argument("--sweep", action="store_true", help="try scale/roll variants, print seam error")
    a = ap.parse_args()
    lenses = load_calibration(a.insv)
    frames = [decode(a.insv, t, a.frame) for t in (0, 1)]
    if a.sweep:
        for f_div in (5376, 5312, 5632):
            for c_div in (5376, 5632):
                for roll_sign in (0, 1, -1):
                    _, err = stitch(frames, lenses, 2048, f_div, c_div, roll_sign)
                    print(f"f_div={f_div} c_div={c_div} roll_sign={roll_sign:+d} seam_err={err:.2f}")
    else:
        img, err = stitch(frames, lenses, a.width)
        cv2.imwrite(a.out, img, [cv2.IMWRITE_JPEG_QUALITY, 92])
        print(f"wrote {a.out} seam_err={err:.2f}")
