#!/usr/bin/env python3
"""Generates Snapper's film-damage textures (our own, so no licence strings).

    python3 tools/lutgen/textures.py

Writes Snapper/Resources/Textures/film-dust-<n>.png: white-on-black damage
that the app's `dust` effect screens over a photo (LookPipeline+Effects).
Each texture keeps three layers apart in its colour channels:

    red    dust: specks from pinpricks to irregular blobs and short streaks
    green  hairs: long wavy fibres, plus faint full-height scratches
    blue   scratch bands: clusters of short horizontal dashes

The app picks one texture per photo (from its seed), flips it and moves it,
so neighbouring frames don't repeat. Drawn at 2x and downsampled for smooth
edges. Seeds are fixed, so re-running reproduces the same files.
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Snapper/Resources/Textures"
SIZE = 2048          # final texture size
SCALE = 2            # supersampling
COUNT = 4            # variants


def dust_layer(rng: np.random.Generator) -> Image.Image:
    s = SIZE * SCALE
    img = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(img)
    for _ in range(rng.integers(900, 1400)):
        x, y = rng.uniform(0, s, 2)
        # Mostly pinpricks, a few larger pieces (Pareto-like sizes).
        r = min((rng.pareto(3.0) + 1) * 1.1 * SCALE, 6 * SCALE)
        level = int(rng.uniform(0.5, 1.0) * 255)
        kind = rng.random()
        if kind < 0.8:
            if r > 2.5 * SCALE:  # irregular blob, never a clean circle
                n = rng.integers(7, 12)
                angles = np.sort(rng.uniform(0, 2 * math.pi, n))
                radii = r * rng.uniform(0.45, 1.2, n)
                d.polygon([(x + math.cos(a) * rr, y + math.sin(a) * rr) for a, rr in zip(angles, radii)], fill=level)
            else:
                rx, ry = r * rng.uniform(0.6, 1.0), r * rng.uniform(0.6, 1.0)
                d.ellipse([x - rx, y - ry, x + rx, y + ry], fill=level)
        elif kind < 0.92:  # short streak, mostly horizontal
            length = r * rng.uniform(3, 10)
            a = rng.normal(0, 0.25)
            d.line([x, y, x + math.cos(a) * length, y + math.sin(a) * length],
                   fill=level, width=max(1, int(r * 0.5)))
        else:  # clump of fine grit
            for _ in range(rng.integers(5, 14)):
                ox, oy = rng.normal(0, r * 2.5, 2)
                rr = rng.uniform(0.5, 1.1) * SCALE
                d.ellipse([x + ox - rr, y + oy - rr, x + ox + rr, y + oy + rr], fill=level)
    return img


def hair_layer(rng: np.random.Generator) -> Image.Image:
    s = SIZE * SCALE
    img = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(img)
    for _ in range(rng.integers(1, 3)):
        # A fibre: long and gently wavy, drifting mostly one way.
        x, y = rng.uniform(0.05 * s, 0.95 * s, 2)
        heading = rng.uniform(0, 2 * math.pi)
        f1, f2 = rng.uniform(0.01, 0.03), rng.uniform(0.06, 0.12)
        p1, p2 = rng.uniform(0, 2 * math.pi, 2)
        drift = 0.0
        points = [(x, y)]
        for i in range(int(rng.uniform(0.5, 0.95) * s / (4 * SCALE))):
            drift += rng.normal(0, 0.01)
            angle = heading + 0.45 * math.sin(i * f1 + p1) + 0.12 * math.sin(i * f2 + p2) + drift
            x += math.cos(angle) * 4 * SCALE
            y += math.sin(angle) * 4 * SCALE
            points.append((x, y))
        d.line(points, fill=int(rng.uniform(0.7, 0.95) * 255), width=int(rng.uniform(1.2, 2.0) * SCALE), joint="curve")
    for _ in range(rng.integers(1, 4)):
        # Faint, slightly wobbly full-height scratch.
        x = rng.uniform(0, s)
        ys = np.linspace(0, s, 60)
        xs = x + np.cumsum(rng.normal(0, 0.6 * SCALE, ys.size))
        d.line(list(zip(xs, ys)), fill=int(rng.uniform(0.25, 0.5) * 255), width=max(1, int(0.8 * SCALE)))
    return img


def band_layer(rng: np.random.Generator) -> Image.Image:
    s = SIZE * SCALE
    img = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(img)
    for _ in range(rng.integers(1, 4)):
        # A band of short horizontal dashes, densest in its middle.
        cy = rng.uniform(0.15 * s, 0.85 * s)
        spread = rng.uniform(25, 80) * SCALE
        for _ in range(rng.integers(400, 900)):
            y = rng.normal(cy, spread)
            x = rng.uniform(0, s)
            length = min(rng.lognormal(math.log(10 * SCALE), 0.8), 90 * SCALE)
            level = int(rng.uniform(0.45, 1.0) * 255)
            d.line([x, y, x + length, y + rng.normal(0, 0.6 * SCALE)], fill=level, width=max(1, int(rng.uniform(0.8, 2.0) * SCALE)))
    for _ in range(rng.integers(8, 20)):
        # A few stray dashes anywhere.
        x, y = rng.uniform(0, s, 2)
        length = rng.uniform(10, 50) * SCALE
        d.line([x, y, x + length, y], fill=int(rng.uniform(0.5, 0.9) * 255), width=max(1, int(1.2 * SCALE)))
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for n in range(1, COUNT + 1):
        rng = np.random.default_rng(1000 + n)
        layers = [dust_layer(rng), hair_layer(rng), band_layer(rng)]
        rgb = Image.merge("RGB", [layer.resize((SIZE, SIZE), Image.LANCZOS) for layer in layers])
        path = OUT / f"film-dust-{n}.png"
        rgb.save(path, optimize=True)
        print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
