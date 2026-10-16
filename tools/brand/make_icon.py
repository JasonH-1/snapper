#!/usr/bin/env python3
"""Renders the Snapper app icon (1024x1024, opaque PNG) into the asset catalog.

The mark is a camera lens whose ring is a conic gradient through the three
look families (warm disposable amber, neon rose, soft-film teal) on a deep
night background. Drawn at 2x and downsampled for clean anti-aliasing.

    python3 tools/brand/make_icon.py
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Snapper/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

S = 2048  # supersampled canvas


def hex_rgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def main() -> None:
    y, x = np.mgrid[0:S, 0:S].astype(np.float64)
    u = (x + 0.5) / S
    v = (y + 0.5) / S
    cx, cy = 0.5, 0.5
    dx, dy = u - cx, v - cy
    r = np.sqrt(dx * dx + dy * dy)
    ang = (np.arctan2(dy, dx) + np.pi) / (2 * np.pi)  # 0..1

    # Background: vertical night gradient with a soft warm glow behind the lens.
    top, bottom = hex_rgb("#231A3A"), hex_rgb("#0B0910")
    bg = top[None, None, :] * (1 - v[..., None]) + bottom[None, None, :] * v[..., None]
    glow = np.exp(-((r / 0.42) ** 2))[..., None]
    bg = bg + glow * hex_rgb("#3A2450")[None, None, :] * 0.55

    # Conic ring colours: amber -> rose -> violet -> teal -> amber.
    stops = [
        (0.00, hex_rgb("#FFC15E")),
        (0.25, hex_rgb("#FF6B6B")),
        (0.50, hex_rgb("#B07CFF")),
        (0.75, hex_rgb("#37D3C4")),
        (1.00, hex_rgb("#FFC15E")),
    ]
    a = (ang + 0.10) % 1.0
    ring_col = np.zeros((S, S, 3))
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (a >= p0) & (a < p1)
        t = ((a - p0) / (p1 - p0))[..., None]
        t = t * t * (3 - 2 * t)
        ring_col = np.where(m[..., None], c0 * (1 - t) + c1 * t, ring_col)

    img = bg.copy()

    # Outer lens body (dark ring with subtle bevel).
    R_outer, R_ring_out, R_ring_in, R_glass = 0.345, 0.315, 0.235, 0.205
    aa = 1.5 / S
    body = smoothstep(R_outer + aa, R_outer - aa, r)[..., None]
    body_col = hex_rgb("#17121F")[None, None, :] + (0.06 * (0.5 - v))[..., None]
    img = img * (1 - body) + body_col * body

    # Gradient ring.
    ring = (smoothstep(R_ring_out + aa, R_ring_out - aa, r) * smoothstep(R_ring_in - aa, R_ring_in + aa, r))[..., None]
    shade = (0.85 + 0.25 * (0.5 - v))[..., None]
    img = img * (1 - ring) + np.clip(ring_col * shade, 0, 1) * ring

    # Inner glass: deep radial gradient.
    glass = smoothstep(R_glass + aa, R_glass - aa, r)[..., None]
    gr = np.clip(r / R_glass, 0, 1)
    glass_col = hex_rgb("#2A2140")[None, None, :] * (1 - gr[..., None]) + hex_rgb("#08060C")[None, None, :] * gr[..., None]
    img = img * (1 - glass) + glass_col * glass

    # Iris highlight dot and specular crescent.
    hx, hy = cx - 0.065, cy - 0.07
    hr = np.sqrt((u - hx) ** 2 + (v - hy) ** 2)
    spec = (smoothstep(0.047, 0.044, hr) * 0.9)[..., None]
    img = img * (1 - spec) + np.ones(3) * spec
    sx, sy = cx + 0.06, cy + 0.075
    sr = np.sqrt((u - sx) ** 2 + (v - sy) ** 2)
    spec2 = (smoothstep(0.019, 0.016, sr) * 0.5)[..., None]
    img = img * (1 - spec2) + np.ones(3) * spec2

    # Inner rim light on the glass edge.
    rim = (np.exp(-(((r - R_glass) / 0.004) ** 2)) * 0.25 * np.clip(0.5 - dy * 3, 0, 1))[..., None]
    img = np.clip(img + rim, 0, 1)

    out = Image.fromarray((img * 255 + 0.5).astype(np.uint8), "RGB")
    out = out.resize((1024, 1024), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    out.save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
