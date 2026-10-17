#!/usr/bin/env python3
"""The clip tag: a small black-and-white code the import puts in an unused corner of each clip.

The fisheye picture is round, so the corners of each lens image are always black and never used.
The import overlays two 4 x 4 grids of cells in the left lens's top-left and bottom-left corners,
32 bits in all: a 24-bit clip number and an 8-bit check. The plugin reads them back
(plugin/src/ClipTag.h, same layout) to find the clip's files in the registry, whatever the
timeline size, since the code scales with the picture.

Standard library only (it writes the PNG itself): it runs in DaVinci Resolve's own Python.
"""
import struct
import zlib

GRID = 4                  # cells per side of each block
BLOCK_START = 0.02        # block position and size, as fractions of the lens image
BLOCK_SIZE = 0.11
CHECK_XOR = 0x5A          # so that an all-black corner never reads as a valid tag


def check_byte(clip_id):
    crc = 0
    for byte in clip_id.to_bytes(3, "big"):
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc ^ CHECK_XOR


def tag_bits(clip_id):
    value = (clip_id & 0xFFFFFF) | (check_byte(clip_id & 0xFFFFFF) << 24)
    return [(value >> i) & 1 for i in range(32)]


def cell_rect(bit, width, height):
    """Pixel rectangle (x0, y0, x1, y1) of a bit's cell, y from the top, in a side-by-side frame."""
    block, cell = divmod(bit, GRID * GRID)
    row, col = divmod(cell, GRID)
    tile_w = width / 2
    step = BLOCK_SIZE / GRID
    x0 = (BLOCK_START + col * step) * tile_w
    top = BLOCK_START if block == 0 else 1.0 - BLOCK_START - BLOCK_SIZE
    y0 = (top + row * step) * height
    return int(round(x0)), int(round(y0)), int(round(x0 + step * tile_w)), int(round(y0 + step * height))


def write_tag_png(clip_id, path, width=2048, height=1024):
    """Transparent image the size of the side-by-side frame, with the code in its corners."""
    pixels = bytearray(width * height * 4)
    for bit, on in enumerate(tag_bits(clip_id)):
        x0, y0, x1, y1 = cell_rect(bit, width, height)
        colour = b"\xff\xff\xff\xff" if on else b"\x00\x00\x00\xff"
        for y in range(y0, y1):
            pixels[(y * width + x0) * 4:(y * width + x1) * 4] = colour * (x1 - x0)
    raw = b"".join(b"\x00" + bytes(pixels[y * width * 4:(y + 1) * width * 4]) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def read_tag(get_pixel, width, height):
    """Decodes a tag; get_pixel(x, y) returns brightness 0..1 with y from the top. None if absent."""
    value = 0
    for bit in range(32):
        x0, y0, x1, y1 = cell_rect(bit, width, height)
        if get_pixel((x0 + x1) // 2, (y0 + y1) // 2) > 0.5:
            value |= 1 << bit
    clip_id = value & 0xFFFFFF
    return clip_id if (value >> 24) == check_byte(clip_id) else None
