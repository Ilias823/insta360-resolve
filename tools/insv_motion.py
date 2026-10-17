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
"""
import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from insv_trailer import proto_fields, read_records

GYRO, EXPOSURE = 3, 4
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


def motion_data(path, frame_count, fps, camera):
    """Bytes of the .motion file for a clip, or None if it has no usable sensor data."""
    if camera not in SUPPORTED_CAMERAS:
        return None
    records = read_records(str(path))["records"]
    if GYRO not in records or EXPOSURE not in records:
        return None
    raw = records[GYRO]["data"]
    samples = list(struct.iter_unpack("<Q6H", raw[:len(raw) // 20 * 20]))
    exposures = [t for t, _ in struct.iter_unpack("<Qd", records[EXPOSURE]["data"][:len(records[EXPOSURE]["data"]) // 16 * 16])]
    if len(samples) < 100 or not exposures:
        return None
    first = next((v for n, wt, v in proto_fields(records[1]["data"]) if n == FIRST_FRAME_FIELD and wt == 0), None)
    offset = (first - exposures[0]) if first else 165000   # microseconds; measured value if missing

    def frame_time(k):
        """Frame k on the sensor clock, microseconds."""
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
    return bytes(out)


if __name__ == "__main__":
    import json
    clip, info_path, out = sys.argv[1:4]
    info = json.loads(Path(info_path).read_text())
    data = motion_data(clip, info["frames"], float(info["fps"]), info["camera"])
    if data is None:
        sys.exit("no usable motion data")
    Path(out).write_bytes(data)
    print(f"{info['frames']} frames, {len(data)} bytes")
