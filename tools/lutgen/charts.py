"""Synthetic test charts used alongside real photos in the contact sheets.

  skin    Monk Skin Tone Scale rendered as lit spheres (highlight -> shadow)
  colour  24-patch colour checker (published sRGB values) + smooth gradients
  night   neon-lit night scene: deep shadows, saturated light sources, glow
"""
from __future__ import annotations

import numpy as np

from quality import MONK_SCALE, hex_to_rgb
from engine import linear_to_srgb, srgb_to_linear

CHECKER = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
    (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
    (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]


def skin_chart(w: int = 900, h: int = 600) -> np.ndarray:
    img = np.full((h, w, 3), srgb_to_linear(np.array([0.82, 0.82, 0.80])))
    cols, rows = 5, 2
    cw, ch = w / cols, h / rows
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    for i, hx in enumerate(MONK_SCALE):
        cx = (i % cols + 0.5) * cw
        cy = (i // cols + 0.5) * ch
        r = min(cw, ch) * 0.42
        dx, dy = (xx - cx) / r, (yy - cy) / r
        d2 = dx * dx + dy * dy
        inside = d2 <= 1.0
        nz = np.sqrt(np.clip(1.0 - d2, 0.0, 1.0))
        # Key light from upper left, soft fill, a little specular.
        lx, ly, lz = -0.45, -0.55, 0.70
        lam = np.clip(dx * lx + dy * ly + nz * lz, 0.0, 1.0)
        shade = 0.10 + 1.15 * lam
        spec = np.clip(dx * -0.3 + dy * -0.4 + nz * 0.86, 0, 1) ** 40 * 0.25
        base = srgb_to_linear(hex_to_rgb(hx))
        col = base[None, None, :] * shade[..., None] + spec[..., None]
        img = np.where(inside[..., None], col, img)
    return np.clip(linear_to_srgb(np.clip(img, 0, 1)), 0, 1)


def colour_chart(w: int = 900, h: int = 600) -> np.ndarray:
    img = np.zeros((h, w, 3)) + 0.12
    top = int(h * 0.62)
    cols, rows = 6, 4
    pad = 6
    cw, ch = (w - pad) / cols, (top - pad) / rows
    for i, rgb in enumerate(CHECKER):
        x0 = int(pad + (i % cols) * cw)
        y0 = int(pad + (i // cols) * ch)
        img[y0:int(y0 + ch - pad), x0:int(x0 + cw - pad)] = np.array(rgb) / 255.0
    # Gradients: grey ramp, hue sweep at moderate saturation, sky.
    gh = (h - top - 4 * pad) // 3
    t = np.linspace(0, 1, w - 2 * pad)
    y = top + pad
    img[y:y + gh, pad:w - pad] = t[None, :, None]
    y += gh + pad
    hue = t * 6.0
    k = lambda n: np.clip(np.abs(((hue + n) % 6.0) - 3.0) - 1.0, 0, 1)  # noqa: E731
    sweep = np.stack([k(0), k(4), k(2)], axis=-1) * 0.55 + 0.25
    img[y:y + gh, pad:w - pad] = sweep[None, :, :]
    y += gh + pad
    sky = np.array([0.18, 0.36, 0.66])[None, :] * (1 - t[:, None]) + np.array([0.86, 0.92, 0.98])[None, :] * t[:, None]
    img[y:y + gh, pad:w - pad] = sky[None, :, :]
    return np.clip(img, 0, 1)


def night_chart(w: int = 900, h: int = 600) -> np.ndarray:
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    u, v = xx / w, yy / h
    # Dark street: blue-black sky fading to a slightly lit wet ground.
    lin = np.zeros((h, w, 3))
    lin += np.array([0.004, 0.006, 0.014])[None, None, :] * (1.2 - v[..., None])
    lin += np.array([0.010, 0.008, 0.012])[None, None, :] * np.clip((v[..., None] - 0.65) * 3, 0, 1)

    def tube(x0, y0, x1, y1, color, intensity=6.0, glow=0.06):
        px, py = u - x0, v - y0
        sx, sy = x1 - x0, y1 - y0
        t = np.clip((px * sx + py * sy) / (sx * sx + sy * sy), 0, 1)
        d = np.hypot(px - t * sx, (py - t * sy) * h / w)
        core = np.exp(-(d / 0.004) ** 2) * intensity
        halo = np.exp(-(d / glow) ** 2) * intensity * 0.06
        return (core + halo)[..., None] * np.array(color)[None, None, :]

    lin += tube(0.08, 0.18, 0.40, 0.18, (1.0, 0.10, 0.45))       # magenta sign
    lin += tube(0.08, 0.30, 0.40, 0.30, (0.10, 0.85, 1.0))       # cyan sign
    lin += tube(0.58, 0.10, 0.58, 0.48, (1.0, 0.55, 0.08), 5.0)  # amber vertical sign
    lin += tube(0.70, 0.22, 0.92, 0.22, (0.55, 0.20, 1.0), 4.0)  # violet sign
    lin += tube(0.70, 0.36, 0.92, 0.36, (1.0, 0.18, 0.12), 4.0)  # red sign
    # Wet-street reflections.
    refl = np.exp(-((u - 0.24) / 0.10) ** 2) * np.exp(-((v - 0.86) / 0.06) ** 2)
    lin += refl[..., None] * np.array([0.30, 0.25, 0.45])[None, None, :]
    # A face-coloured sphere lit by the amber sign (skin under mixed light).
    cx, cy, r = 0.78, 0.70, 0.11
    dx, dy = (u - cx) / r, (v - cy) / r * (h / w)
    d2 = dx * dx + dy * dy
    nz = np.sqrt(np.clip(1 - d2, 0, 1))
    lam = np.clip(dx * -0.6 + dy * -0.5 + nz * 0.6, 0, 1)
    rim = np.clip(dx * 0.8 + nz * 0.2, 0, 1) ** 3
    skin = srgb_to_linear(hex_to_rgb("#c8957a"))
    face = skin[None, None, :] * (lam[..., None] * np.array([1.0, 0.85, 0.65]) * 0.55 + rim[..., None] * np.array([0.3, 0.7, 1.0]) * 0.35 + 0.02)
    lin = np.where((d2 <= 1)[..., None], face, lin)
    # Gentle filmic shoulder so the light sources do not clip to flat white.
    peak = np.max(lin, axis=-1, keepdims=True)
    lin = lin * np.where(peak > 0.7, (0.7 + 0.3 * (1 - np.exp(-(peak - 0.7) / 0.3))) / np.maximum(peak, 1e-9), 1.0)
    return np.clip(linear_to_srgb(np.clip(lin, 0, 1)), 0, 1)


CHARTS = {
    "chart-skin": skin_chart,
    "chart-colour": colour_chart,
    "chart-night": night_chart,
}
