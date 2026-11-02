#!/usr/bin/env python3
"""Camera motion of an Insta360 X5 clip, from the gyroscope and accelerometer in its trailer.

Writes <name>.motion next to the lens files: for every video frame, the camera's orientation
relative to the first frame, and the direction of "up" measured by the accelerometer. The plugin
reads it to stabilise the picture (plugin/src/Motion.cpp).

Standard library only: it runs in DaVinci Resolve's own Python.

The sensor layout follows the Apache-2.0 telemetry-parser project (github.com/AdrianEddy/
telemetry-parser); the X5's axes, ranges and timing were measured against its video:
rig x = sensor z, y = sensor x, z = sensor y; 2000 deg/s and 8 g ranges; frame k is seen at
first_frame_timestamp + (exposure time of frame k - exposure time of frame 0) on the sensor clock.

Timelapse and hyperlapse clips keep only some of the frames the sensor saw (a 10x hyperlapse: one in
ten), so their video frames are not evenly related to the exposure list. Record 6 then gives each
kept frame's time, on the same clock as the gyro (measured offset: 0 ms). Slow timelapses have no gyro
at all; record 24 holds the orientation the camera worked out around each kept frame: a double time
in seconds and four doubles, w x z y, in a world whose up is -y, so it also gives the horizon.
Its axes relate to the rig as rig x = -z, y = y, z = x (fitted against the gyro: 0.16 degrees).
"""
import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from insv_trailer import proto_fields, read_records

GYRO, EXPOSURE, FRAME_TIMES, CAMERA_ORIENTATION = 3, 4, 6, 24
FIRST_FRAME_FIELD = 24          # metadata: first frame time on the sensor clock, microseconds
GYRO_RANGE_DPS, ACC_RANGE_G = 2000.0, 8.0
UP_WINDOW_S = 0.25              # the accelerometer is averaged over this long around each frame
MAGIC = b"I360MOT1"
SUPPORTED_CAMERAS = ("Insta360 X5",)


def _quat_mul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (aw * bw - ax * bx - ay * by - az * bz,
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw)


def _quat_from_rotvec(x, y, z):
    angle = math.sqrt(x * x + y * y + z * z)
    if angle < 1e-12:
        return (1.0, 0.5 * x, 0.5 * y, 0.5 * z)
    s = math.sin(angle / 2) / angle
    return (math.cos(angle / 2), x * s, y * s, z * s)


def _normalised(q):
    n = math.sqrt(sum(c * c for c in q))
    return tuple(c / n for c in q)


def _rotated_by_inverse(q, v):
    """v turned by the inverse of unit quaternion q."""
    w, x, y, z = q
    t = (2 * (y * v[2] - z * v[1]), 2 * (z * v[0] - x * v[2]), 2 * (x * v[1] - y * v[0]))
    return (v[0] - w * t[0] + y * t[2] - z * t[1],
            v[1] - w * t[1] + z * t[0] - x * t[2],
            v[2] - w * t[2] + x * t[1] - y * t[0])


def _orientation_motion(records, frame_times, frame_count, fps):
    """Motion of a clip without gyro, from the camera's own orientation record (see the top)."""
    if CAMERA_ORIENTATION not in records or not frame_times:
        return None
    raw = records[CAMERA_ORIENTATION]["data"]
    # Stored w x z y; as (w, x, y, z) in the camera's own axes.
    entries = [(t, (w, x, y, z)) for t, w, x, z, y in struct.iter_unpack("<d4d", raw[:len(raw) // 40 * 40])]
    if not entries:
        return None
    out = bytearray(MAGIC + struct.pack("<If", frame_count, fps))
    i, start = 0, None
    for k in range(frame_count):
        t = frame_times[min(k, len(frame_times) - 1)] * 1e-6
        while i + 1 < len(entries) and abs(entries[i + 1][0] - t) <= abs(entries[i][0] - t):
            i += 1
        q = entries[i][1]
        if start is None:
            start = (q[0], -q[1], -q[2], -q[3])
        w, x, y, z = _normalised(_quat_mul(start, q))
        ux, uy, uz = _rotated_by_inverse(q, (0.0, -1.0, 0.0))   # the world's up, seen from the camera
        # Into rig axes: x = -z, y = y, z = x.
        out += struct.pack("<7f", w, -z, y, x, -uz, uy, ux)
    return bytes(out)


def motion_data(path, frame_count, fps, camera):
    """Bytes of the .motion file for a clip, or None if it has no usable sensor data."""
    if camera not in SUPPORTED_CAMERAS:
        return None
    records = read_records(str(path))["records"]
    frame_times = []
    if FRAME_TIMES in records:
        frame_times = [t for (t,) in struct.iter_unpack("<Q", records[FRAME_TIMES]["data"][:len(records[FRAME_TIMES]["data"]) // 8 * 8])]
    # The camera's own orientation does not drift over a long clip, where the integrated gyro did
    # (60 degrees over a 5 minute hyperlapse), and follows the picture as closely frame to frame.
    # After the frames, on sped-up clips: seconds of recording per second of video.
    tail = b""
    if len(frame_times) > 1 and frame_times[-1] > frame_times[0]:
        tail = struct.pack("<f", (frame_times[-1] - frame_times[0]) / 1e6 / ((len(frame_times) - 1) / fps))
    data = _orientation_motion(records, frame_times, frame_count, fps)
    if data or GYRO not in records:
        return data + tail if data else data
    if EXPOSURE not in records and not frame_times:
        return None
    raw = records[GYRO]["data"]
    samples = list(struct.iter_unpack("<Q6H", raw[:len(raw) // 20 * 20]))
    exposures = []
    if EXPOSURE in records:
        exposures = [t for t, _ in struct.iter_unpack("<Qd", records[EXPOSURE]["data"][:len(records[EXPOSURE]["data"]) // 16 * 16])]
    if len(samples) < 100 or not (exposures or frame_times):
        return None
    first = next((v for n, wt, v in proto_fields(records[1]["data"]) if n == FIRST_FRAME_FIELD and wt == 0), None)
    offset = (first - exposures[0]) if first and exposures else 165000   # microseconds; measured value if missing

    def frame_time(k):
        """Frame k on the sensor clock, microseconds."""
        if frame_times:
            if k < len(frame_times):
                return frame_times[k]
            step = frame_times[-1] - frame_times[-2] if len(frame_times) > 1 else 1e6 / fps
            return frame_times[-1] + (k - len(frame_times) + 1) * step
        if k < len(exposures):
            return exposures[k] + offset
        return exposures[-1] + offset + (k - len(exposures) + 1) * 1e6 / fps

    gyro_scale = math.radians(GYRO_RANGE_DPS) / 32768.0
    acc_scale = ACC_RANGE_G / 32768.0
    # Rig axes from sensor axes (x right, y down, z forward through lens A).
    times = [s[0] for s in samples]
    rates = [((s[6] - 32768) * gyro_scale, (s[4] - 32768) * gyro_scale, (s[5] - 32768) * gyro_scale) for s in samples]
    accel = [((s[3] - 32768) * acc_scale, (s[1] - 32768) * acc_scale, (s[2] - 32768) * acc_scale) for s in samples]

    # Orientation (camera to world), integrated from body rates, read at each frame time.
    out = bytearray(MAGIC + struct.pack("<If", frame_count, fps))
    q = (1.0, 0.0, 0.0, 0.0)
    i, start = 0, None
    lo = hi = 0
    acc_sum = [0.0, 0.0, 0.0]
    half = UP_WINDOW_S * 1e6 / 2
    for k in range(frame_count):
        t = frame_time(k)
        while i + 1 < len(times) and times[i + 1] <= t:
            dt = (times[i + 1] - times[i]) * 1e-6
            q = _normalised(_quat_mul(q, _quat_from_rotvec(*(r * dt for r in rates[i]))))
            i += 1
        if start is None:
            start = (q[0], -q[1], -q[2], -q[3])          # orientation of frame 0, inverted
        rel = _normalised(_quat_mul(start, q))
        # Running window of accelerometer samples around the frame.
        while hi < len(times) and times[hi] <= t + half:
            acc_sum = [a + b for a, b in zip(acc_sum, accel[hi])]
            hi += 1
        while lo < hi and times[lo] < t - half:
            acc_sum = [a - b for a, b in zip(acc_sum, accel[lo])]
            lo += 1
        n = math.sqrt(sum(a * a for a in acc_sum)) or 1.0
        out += struct.pack("<7f", *rel, *(a / n for a in acc_sum))
    return bytes(out) + tail


if __name__ == "__main__":
    import json
    clip, info_path, out = sys.argv[1:4]
    info = json.loads(Path(info_path).read_text())
    data = motion_data(clip, info["frames"], float(info["fps"]), info["camera"])
    if data is None:
        sys.exit("no usable motion data")
    Path(out).write_bytes(data)
    print(f"{info['frames']} frames, {len(data)} bytes")
