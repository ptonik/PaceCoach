#!/usr/bin/env python3
"""Draws icon.png for the app: a bent corner arrow on a dark rounded square.

Pure standard library, no image packages needed:
    python3 tools/make_icon.py
"""

import math
import os
import struct
import zlib

SIZE = 128
BG = (22, 26, 34)
ARROW = (255, 150, 40)


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy
    t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
    return math.hypot(px - (ax + dx * t), py - (ay + dy * t))


def rounded_alpha(x, y, radius):
    """Coverage of a rounded square filling the whole image."""
    cx = min(max(x, radius), SIZE - radius)
    cy = min(max(y, radius), SIZE - radius)
    d = math.hypot(x - cx, y - cy)
    return max(0.0, min(1.0, radius - d + 0.5))


def main():
    # Stem up, bend to the right, arrow head.
    s = SIZE
    stem = (0.36 * s, 0.86 * s, 0.36 * s, 0.50 * s)
    bend = (0.36 * s, 0.50 * s, 0.68 * s, 0.30 * s)
    dx, dy = bend[2] - bend[0], bend[3] - bend[1]
    length = math.hypot(dx, dy)
    dx, dy = dx / length, dy / length
    px, py = -dy, dx
    head = 0.20 * s
    tip = (bend[2] + dx * 0.04 * s, bend[3] + dy * 0.04 * s)
    segments = [
        stem, bend,
        (tip[0], tip[1], tip[0] - dx * head + px * head * 0.7, tip[1] - dy * head + py * head * 0.7),
        (tip[0], tip[1], tip[0] - dx * head - px * head * 0.7, tip[1] - dy * head - py * head * 0.7),
    ]
    half = 0.065 * s

    rows = []
    for y in range(SIZE):
        row = bytearray([0])
        for x in range(SIZE):
            fx, fy = x + 0.5, y + 0.5
            alpha = rounded_alpha(fx, fy, 0.2 * s)
            d = min(seg_dist(fx, fy, *seg) for seg in segments)
            ink = max(0.0, min(1.0, half - d + 0.5))
            r = BG[0] + (ARROW[0] - BG[0]) * ink
            g = BG[1] + (ARROW[1] - BG[1]) * ink
            b = BG[2] + (ARROW[2] - BG[2]) * ink
            row += bytes((int(r), int(g), int(b), int(alpha * 255)))
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
    png += chunk(b'IEND', b'')

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'icon.png')
    with open(out, 'wb') as f:
        f.write(png)
    print('wrote', os.path.normpath(out), len(png), 'bytes')


if __name__ == '__main__':
    main()
