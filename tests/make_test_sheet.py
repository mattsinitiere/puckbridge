#!/usr/bin/env python3
"""Draws petdex-layout sprite sheets (8 x 9 cells) for testing the custom-character encoder. Standard library only.

    python3 tests/make_test_sheet.py pixel out.png    # 1536 x 1872, pixel art drawn at 4x (exercises the cell factor)
    python3 tests/make_test_sheet.py smooth out.png   # 768 x 936, gradients + soft edges (exercises the palette)
"""
import math, struct, sys, zlib

ROW_FRAMES = [4, 0, 0, 2, 0, 0, 2, 6, 1]  # idle, runningRight, runningLeft, waving, jumping, failed, waiting, running, review


def png(path, w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def main(kind, path):
    full = kind == "pixel"
    cw, ch = (192, 208) if full else (96, 104)
    w, h = cw * 8, ch * 9
    px = bytearray(w * h * 4)
    k = 4 if full else 1
    for row, count in enumerate(ROW_FRAMES):
        for col in range(count):
            phase = col / max(1, count)
            for y in range(0, ch, k):
                for x in range(0, cw, k):
                    u, v = (x + k / 2) / cw - 0.5, (y + k / 2) / ch - 0.55 - 0.05 * math.sin(phase * 2 * math.pi)
                    d = math.hypot(u * 1.2, v)
                    if d > 0.32:
                        continue
                    if full:
                        rgba = (230, 120, 60, 255) if d < 0.28 else (60, 30, 20, 255)
                        if abs(u + 0.1) < 0.04 and abs(v + 0.08) < 0.04 or abs(u - 0.1) < 0.04 and abs(v + 0.08) < 0.04:
                            rgba = (20, 20, 20, 255)
                    else:
                        a = 255 if d < 0.3 else int(255 * (0.32 - d) / 0.02)
                        rgba = (int(255 * (0.5 + u)), int(200 * (0.5 + v)), 40 * row % 256, max(0, min(255, a)))
                    for yy in range(y, min(y + k, ch)):
                        for xx in range(x, min(x + k, cw)):
                            o = ((row * ch + yy) * w + col * cw + xx) * 4
                            px[o:o + 4] = bytes(rgba)
    png(path, w, h, px)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
