#!/usr/bin/env python3
"""Generate Mouse Tracer SoftCircle_N.tga assets (reproducible recipe).

The checked-in SoftCircle_10..100.tga files under
SpectrumFederation/media/MouseTracer/ are white RGB 64x64 TGAs whose alpha
carries a progressive radial feather. Issue #454 confirmed those assets already
contain the intended falloff; the runtime soft path was adjusted instead of
replacing them. Keep this recipe so assets can be regenerated if Retail QA
later requires a different precomputed falloff (for example, further ADD
compensation).

Recipe:
  - 64x64 uncompressed TGA, 32-bit BGRA, bottom-left origin, white RGB
  - Softness s in {10,20,...,100} as fraction s/100
  - Opaque core shrinks and cosine falloff gamma rises with s
  - Exterior alpha is 0; center is 255; mid-radius alpha decreases as s rises

Usage:
  python3 tools/generate_mouse_tracer_soft_circles.py
"""

from __future__ import annotations

import math
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT = REPO_ROOT / "SpectrumFederation" / "media" / "MouseTracer"
SIZE = 64
R = SIZE / 2.0 - 0.5


def stamp_alpha(softness_pct: int) -> list[list[float]]:
    s = softness_pct / 100.0
    core_frac = max(0.02, (1.0 - s) ** 1.35)
    core = R * core_frac
    gamma = 1.0 + 2.75 * s
    rows: list[list[float]] = []
    cx = cy = (SIZE - 1) / 2.0
    for y in range(SIZE):
        row: list[float] = []
        for x in range(SIZE):
            r = math.hypot(x - cx, y - cy)
            if r <= core:
                row.append(1.0)
            elif r >= R:
                row.append(0.0)
            else:
                t = (r - core) / (R - core)
                smooth = 0.5 + 0.5 * math.cos(math.pi * t)
                row.append(smooth**gamma)
        rows.append(row)
    return rows


def write_tga(path: Path, alpha: list[list[float]]) -> None:
    header = bytearray(18)
    header[2] = 2
    struct.pack_into("<HH", header, 12, SIZE, SIZE)
    header[16] = 32
    header[17] = 8
    body = bytearray(SIZE * SIZE * 4)
    for y in range(SIZE):
        src_y = SIZE - 1 - y
        for x in range(SIZE):
            off = (y * SIZE + x) * 4
            a = int(round(alpha[src_y][x] * 255.0))
            a = 0 if a < 0 else 255 if a > 255 else a
            body[off : off + 4] = bytes((255, 255, 255, a))
    path.write_bytes(bytes(header) + bytes(body))


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for pct in range(10, 101, 10):
        alpha = stamp_alpha(pct)
        path = OUT / f"SoftCircle_{pct}.tga"
        write_tga(path, alpha)
        print(f"wrote {path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
