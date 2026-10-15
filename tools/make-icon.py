#!/usr/bin/env python3
"""Generate megalooper's app icon as a PNG, using only the standard library.

Draws the logo the window's top bar shows (gui-shell.scd, ~guiLogoPaint): a
Möbius loop, a flat ribbon on a lemniscate crossing itself once, with one
half-twist where its width goes through nothing and the side shown flips. On
a rounded square in the window's dark ground, supersampled 4x for clean
edges. Called by make-app.sh, which hands the PNGs to iconutil to build the
.icns, and by install.sh on Linux.

No third-party imaging library on purpose: this has to run on a bare macOS
Python so that rebuilding the icon never becomes a yak-shave before a gig.
"""

import math
import struct
import sys
import zlib

SS = 4  # supersampling factor

# The dark theme's ground and ink (gui-theme.scd); the ribbon's other side is
# the ink at 35 % on the ground, as in the window.
GROUND_TOP = (34, 36, 40)
GROUND_BOTTOM = (13, 14, 16)
INK = (243, 243, 241)


def lerp(a, b, t):
    return a + (b - a) * t


def blend(dst, src, alpha):
    """Composite src over dst with the given alpha, per channel."""
    return tuple(int(round(lerp(d, s, alpha))) for d, s in zip(dst, src))


DIM = blend(GROUND_BOTTOM, INK, 0.35)


def rounded_square_alpha(x, y, size, radius):
    """Coverage of a rounded square centred in a size x size field."""
    inset = size * 0.055
    lo, hi = inset, size - inset
    cx = min(max(x, lo + radius), hi - radius)
    cy = min(max(y, lo + radius), hi - radius)
    if lo <= x <= hi and lo <= y <= hi:
        d = math.hypot(x - cx, y - cy)
        return 1.0 if d <= radius else 0.0
    return 0.0


def ribbon_quads(size, n=400, phase=0.0):
    """The ribbon as quads in drawing order (far first), each with its colour.

    The same geometry as the window's: points on the lemniscate, each normal
    from its two neighbours so the pieces meet without seams, the lobe through
    t = pi/2 passing over the one through 3pi/2. Phase 0 is where the window's
    logo rests with no loop.
    """
    def at(t):
        d = 1 + math.sin(t) ** 2
        return (math.cos(t) / d, math.sin(t) * math.cos(t) / d)

    def normal(t):
        a, b = at(t - 0.001), at(t + 0.001)
        dx, dy = b[0] - a[0], b[1] - a[1]
        l = math.hypot(dx, dy) or 1e-9
        return (-dy / l, dx / l)

    w0 = 0.15
    scale = size * 0.80 / 2.3
    cx = cy = size / 2.0
    step = 2 * math.pi / n
    ts = [k * step for k in range(n + 1)]
    pts = [at(t) for t in ts]
    nrm = [normal(t) for t in ts]
    order = sorted(range(n), key=lambda k: math.sin(ts[k] + step / 2))
    quads = []
    for k in order:
        d0 = (ts[k] - phase) % (2 * math.pi)
        d1 = d0 + step
        wa, wb = w0 * math.cos(d0 / 2), w0 * math.cos(d1 / 2)
        (p0, p1), (n0, n1) = (pts[k], pts[k + 1]), (nrm[k], nrm[k + 1])
        corners = [
            (p0[0] + n0[0] * wa, p0[1] + n0[1] * wa),
            (p1[0] + n1[0] * wb, p1[1] + n1[1] * wb),
            (p1[0] - n1[0] * wb, p1[1] - n1[1] * wb),
            (p0[0] - n0[0] * wa, p0[1] - n0[1] * wa),
        ]
        colour = INK if math.cos((d0 + step / 2) / 2) >= 0 else DIM
        quads.append(([(cx + x * scale, cy + y * scale) for x, y in corners], colour))
    return quads


def fill_polygon(rows, poly, colour, size):
    """Fill a polygon into rows of RGBA bytearrays, a span per scanline
    (even-odd), so the pieces cost their height, not their area."""
    ys = [p[1] for p in poly]
    y_lo, y_hi = max(int(math.floor(min(ys))), 0), min(int(math.ceil(max(ys))), size - 1)
    pixel = bytes((colour[0], colour[1], colour[2], 255))
    edges = list(zip(poly, poly[1:] + poly[:1]))
    for py in range(y_lo, y_hi + 1):
        y = py + 0.5
        xs = []
        for (x0, y0), (x1, y1) in edges:
            if (y0 <= y < y1) or (y1 <= y < y0):
                xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
        xs.sort()
        row = rows[py]
        for i in range(0, len(xs) - 1, 2):
            a = max(int(math.ceil(xs[i] - 0.5)), 0)
            b = min(int(math.floor(xs[i + 1] - 0.5)), size - 1)
            if b >= a:
                # Byte 0 of each row is its PNG filter type.
                row[1 + a * 4:1 + (b + 1) * 4] = pixel * (b + 1 - a)


def render(size):
    big = size * SS
    rows = []
    radius = big * 0.215
    for py in range(big):
        t = py / max(big - 1, 1)
        base = tuple(int(round(lerp(a, b, t))) for a, b in zip(GROUND_TOP, GROUND_BOTTOM))
        row = bytearray()
        row.append(0)  # PNG filter type 0 for this scanline
        for px in range(big):
            if rounded_square_alpha(px + 0.5, py + 0.5, big, radius) <= 0.0:
                row.extend((0, 0, 0, 0))
            else:
                row.extend((base[0], base[1], base[2], 255))
        rows.append(row)
    for poly, colour in ribbon_quads(big):
        fill_polygon(rows, poly, colour, big)
    return big, b"".join(bytes(r) for r in rows)


def downsample(big, raw, size):
    """Box-filter the supersampled RGBA buffer down to size x size."""
    out = []
    stride = big * 4 + 1
    for y in range(size):
        row = bytearray()
        row.append(0)
        for x in range(size):
            r = g = b = a = 0
            for sy in range(SS):
                base = (y * SS + sy) * stride + 1
                for sx in range(SS):
                    o = base + (x * SS + sx) * 4
                    pa = raw[o + 3]
                    r += raw[o] * pa
                    g += raw[o + 1] * pa
                    b += raw[o + 2] * pa
                    a += pa
            n = SS * SS
            if a == 0:
                row.extend((0, 0, 0, 0))
            else:
                row.extend((r // a, g // a, b // a, a // n))
        out.append(bytes(row))
    return b"".join(out)


def write_png(path, size, data):
    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(data, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "megalooper.png"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    big, raw = render(size)
    write_png(out, size, downsample(big, raw, size))
    print(f"wrote {out} ({size}x{size})")


if __name__ == "__main__":
    main()
