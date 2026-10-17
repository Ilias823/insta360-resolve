#!/usr/bin/env python3
"""Read the metadata trailer of an Insta360 .insv file (X5 layout).

Layout, from the end of the file backwards:
  [records...][index record][32 pad][trailer_size u32][version u32][magic 32]
Each record is followed by 6 bytes: [format u8][id u8][size u32 LE].
The index record (id 0) holds 10-byte entries [id u8][format u8][size u32][offset u32],
offsets relative to the start of the trailer.
"""
import json
import os
import re
import struct
import sys

MAGIC = b"8db42d694ccc418790edff439fe026bf"
NAMES = {0: "index", 1: "metadata", 2: "thumbnail", 3: "gyro", 4: "exposure",
         9: "aaa", 10: "anchors", 11: "aaa_sim"}


def read_records(path):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        fh.seek(size - 72)
        foot = fh.read(72)
        if foot[-32:] != MAGIC:
            raise ValueError("no Insta360 trailer found")
        trailer_size, version = struct.unpack("<II", foot[32:40])
        start = size - trailer_size
        fh.seek(size - 78)
        fmt, rid, rsize = struct.unpack("<BBI", fh.read(6))
        if rid != 0:
            raise ValueError("index record not found")
        fh.seek(size - 78 - rsize)
        index = fh.read(rsize)
        records = {}
        for i in range(0, len(index) - 9, 10):
            eid, efmt, esize, eoff = struct.unpack("<BBII", index[i:i + 10])
            if esize == 0:
                continue
            fh.seek(start + eoff)
            records[eid] = {"format": efmt, "size": esize, "offset": eoff,
                            "data": fh.read(esize)}
    return {"trailer_size": trailer_size, "version": version, "records": records}


def proto_fields(buf):
    """Minimal protobuf walk: yields (field_number, wire_type, value)."""
    i, n = 0, len(buf)
    while i < n:
        key = shift = 0
        while True:
            b = buf[i]; i += 1
            key |= (b & 0x7F) << shift; shift += 7
            if b < 0x80:
                break
        num, wt = key >> 3, key & 7
        if wt == 0:
            v = shift = 0
            while True:
                b = buf[i]; i += 1
                v |= (b & 0x7F) << shift; shift += 7
                if b < 0x80:
                    break
            yield num, wt, v
        elif wt == 1:
            yield num, wt, buf[i:i + 8]; i += 8
        elif wt == 5:
            yield num, wt, buf[i:i + 4]; i += 4
        elif wt == 2:
            ln = shift = 0
            while True:
                b = buf[i]; i += 1
                ln |= (b & 0x7F) << shift; shift += 7
                if b < 0x80:
                    break
            yield num, wt, buf[i:i + ln]; i += ln
        else:
            return


SERIAL_FIELD, CAMERA_FIELD, FIRMWARE_FIELD = 1, 2, 3
CALIB_FIELD = 111   # extended calibration string: a count, then 27 values per lens
SENSOR_W = 5376     # calibration is expressed on a 2 x 5376 wide sensor canvas


def read_summary(path):
    """Camera model, firmware and per-lens calibration, ready to write as JSON."""
    recs = read_records(path)["records"]
    fields = {n: v for n, wt, v in proto_fields(recs[1]["data"]) if wt == 2}
    text = fields[CALIB_FIELD].decode()
    vals = [float(x) for x in text.split("_")]
    lenses = []
    for i in range(int(vals[0])):
        s = 1 + i * 27
        lenses.append({
            "xi": vals[s], "fx": vals[s + 1], "fy": vals[s + 2],
            "cx": vals[s + 3] - i * SENSOR_W, "cy": vals[s + 4],
            "yaw": vals[s + 5], "pitch": vals[s + 6], "roll": vals[s + 7],
            "t": vals[s + 8:s + 11], "d": vals[s + 11:s + 24],
        })
    return {"serial": fields.get(SERIAL_FIELD, b"").decode(),
            "camera": fields.get(CAMERA_FIELD, b"").decode(),
            "firmware": fields.get(FIRMWARE_FIELD, b"").decode(),
            "has_gyro": 3 in recs, "sensor_width": SENSOR_W,
            "calibration_raw": text, "lenses": lenses}


if __name__ == "__main__":
    t = read_records(sys.argv[1])
    print(f"trailer {t['trailer_size']} bytes, version {t['version']}")
    for rid, r in sorted(t["records"].items()):
        print(f"  id {rid:3d} {NAMES.get(rid, '?'):10s} fmt {r['format']} size {r['size']}")
    meta = t["records"].get(1)
    if meta:
        print("metadata fields:")
        for num, wt, v in proto_fields(meta["data"]):
            if wt == 2:
                try:
                    s = v.decode("utf-8")
                    shown = s if s.isprintable() else None
                except UnicodeDecodeError:
                    shown = None
                print(f"  #{num}: " + (repr(shown[:400]) if shown is not None else f"<{len(v)} bytes>"))
            elif wt == 0:
                print(f"  #{num}: {v}")
            else:
                print(f"  #{num}: <fixed {len(v)}>")
