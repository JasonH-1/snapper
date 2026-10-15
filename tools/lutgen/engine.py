"""Colour engine for Snapper looks.

A look is a pure function from display-referred sRGB (gamma encoded, 0..1) to
display-referred sRGB. It is sampled on a 33-point grid and written as a .cube
file; the app applies that cube with CIColorCubeWithColorSpace in sRGB, so the
cube sees exactly the values this module sees.

Pipeline (each stage is optional and neutral by default):

  1. decode sRGB -> linear light
  2. white balance (Bradford adaptation along the daylight locus) + tint
  3. exposure (EV)
  4. hue-preserving highlight shoulder on max(R,G,B)   -> no hard clipping
  5. encode back to sRGB gamma, then per-channel tone shaping:
       contrast S-curve around a pivot, master + per-channel curves
       (monotone cubic, so no inversions/banding), black lift / white point
  6. colour work in OkLCh (perceptual): saturation, vibrance, per-hue
     saturation / hue / lightness, split toning, shadow/highlight desaturation
  7. skin protection: hue and chroma of skin-coloured pixels are pulled back
     toward their (white-balanced) input so skin never goes orange, magenta
     or grey
  8. gamut mapping by chroma reduction at constant lightness and hue
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import numpy as np

# --------------------------------------------------------------------------
# Transfer functions and colour spaces


def srgb_to_linear(v: np.ndarray) -> np.ndarray:
    a = np.abs(v)
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    return np.sign(v) * lin


def linear_to_srgb(v: np.ndarray) -> np.ndarray:
    a = np.abs(v)
    enc = np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)
    return np.sign(v) * enc


SRGB_TO_XYZ = np.array([
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041],
])
XYZ_TO_SRGB = np.linalg.inv(SRGB_TO_XYZ)
BRADFORD = np.array([
    [0.8951, 0.2664, -0.1614],
    [-0.7502, 1.7135, 0.0367],
    [0.0389, -0.0685, 1.0296],
])
BRADFORD_INV = np.linalg.inv(BRADFORD)

# Oklab (Björn Ottosson, 2020), from linear sRGB.
_OK_M1 = np.array([
    [0.4122214708, 0.5363325363, 0.0514459929],
    [0.2119034982, 0.6806995451, 0.1073969566],
    [0.0883024619, 0.2817188376, 0.6299787005],
])
_OK_M2 = np.array([
    [0.2104542553, 0.7936177850, -0.0040720468],
    [1.9779984951, -2.4285922050, 0.4505937099],
    [0.0259040371, 0.7827717662, -0.8086757660],
])
_OK_M1_INV = np.linalg.inv(_OK_M1)
_OK_M2_INV = np.linalg.inv(_OK_M2)


def linear_to_oklab(rgb: np.ndarray) -> np.ndarray:
    lms = rgb @ _OK_M1.T
    lms_ = np.cbrt(lms)
    return lms_ @ _OK_M2.T


def oklab_to_linear(lab: np.ndarray) -> np.ndarray:
    lms_ = lab @ _OK_M2_INV.T
    return (lms_ ** 3) @ _OK_M1_INV.T


def lab_to_lch(lab: np.ndarray):
    L = lab[..., 0]
    C = np.hypot(lab[..., 1], lab[..., 2])
    h = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360.0
    return L, C, h


def lch_to_lab(L, C, h) -> np.ndarray:
    hr = np.radians(h)
    return np.stack([L, C * np.cos(hr), C * np.sin(hr)], axis=-1)


def luminance(lin: np.ndarray) -> np.ndarray:
    return lin @ np.array([0.2126729, 0.7151522, 0.0721750])


# --------------------------------------------------------------------------
# Helpers


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def hue_delta(a: np.ndarray, b) -> np.ndarray:
    """Signed shortest angular difference a - b in degrees, in [-180, 180)."""
    return (a - b + 180.0) % 360.0 - 180.0


def monotone_curve(points: list[list[float]]):
    """Fritsch–Carlson monotone cubic through (x, y) points on [0, 1].

    Monotone input points give a monotone, C1-smooth curve, which keeps tone
    curves free of reversals and of the kinks that show up as banding.
    """
    pts = np.array(sorted(points), dtype=np.float64)
    xs, ys = pts[:, 0], pts[:, 1]
    if xs[0] > 0.0:
        xs, ys = np.r_[0.0, xs], np.r_[ys[0], ys]
    if xs[-1] < 1.0:
        xs, ys = np.r_[xs, 1.0], np.r_[ys, ys[-1]]
    h = np.diff(xs)
    delta = np.diff(ys) / h
    n = len(xs)
    m = np.zeros(n)
    m[0], m[-1] = delta[0], delta[-1]
    for k in range(1, n - 1):
        if delta[k - 1] * delta[k] <= 0:
            m[k] = 0.0
        else:
            w1 = 2 * h[k] + h[k - 1]
            w2 = h[k] + 2 * h[k - 1]
            m[k] = (w1 + w2) / (w1 / delta[k - 1] + w2 / delta[k])

    def f(x: np.ndarray) -> np.ndarray:
        xc = np.clip(x, 0.0, 1.0)
        k = np.clip(np.searchsorted(xs, xc, side="right") - 1, 0, n - 2)
        t = (xc - xs[k]) / h[k]
        t2, t3 = t * t, t * t * t
        h00 = 2 * t3 - 3 * t2 + 1
        h10 = t3 - 2 * t2 + t
        h01 = -2 * t3 + 3 * t2
        h11 = t3 - t2
        y = h00 * ys[k] + h10 * h[k] * m[k] + h01 * ys[k + 1] + h11 * h[k] * m[k + 1]
        # Linear continuation outside [0, 1] keeps extended values sane.
        y = np.where(x < 0.0, ys[0] + m[0] * x, y)
        y = np.where(x > 1.0, ys[-1] + m[-1] * (x - 1.0), y)
        return y

    return f


def daylight_xy(cct: float) -> tuple[float, float]:
    """CIE daylight locus chromaticity, extended below 4000 K by clamping."""
    t = float(np.clip(cct, 2500.0, 25000.0))
    if t <= 7000.0:
        x = -4.6070e9 / t ** 3 + 2.9678e6 / t ** 2 + 0.09911e3 / t + 0.244063
    else:
        x = -2.0064e9 / t ** 3 + 1.9018e6 / t ** 2 + 0.24748e3 / t + 0.237040
    y = -3.000 * x * x + 2.870 * x - 0.275
    return x, y


def xy_to_xyz(x: float, y: float) -> np.ndarray:
    return np.array([x / y, 1.0, (1 - x - y) / y])


def white_balance_matrix(temperature: float, tint: float) -> np.ndarray:
    """Linear-sRGB matrix that renders D65 white as a warmer/cooler white.

    temperature: -1..1, positive = warmer. tint: -1..1, positive = magenta.
    """
    if temperature == 0 and tint == 0:
        return np.eye(3)
    src = xy_to_xyz(*daylight_xy(6504.0))
    # Warm = the scene's white is rendered as if lit by a lower colour temperature.
    cct = 6504.0 * 2.0 ** (-temperature * 0.75)
    x, y = daylight_xy(cct)
    y -= 0.010 * tint
    dst = xy_to_xyz(x, y)
    s = BRADFORD @ src
    d = BRADFORD @ dst
    cat = BRADFORD_INV @ np.diag(d / s) @ BRADFORD
    m = XYZ_TO_SRGB @ cat @ SRGB_TO_XYZ
    # Keep the luminance of white unchanged so warmth never reads as exposure.
    white_y = luminance(m @ np.ones(3))
    return m / white_y


# --------------------------------------------------------------------------
# Look parameters

HUE_BANDS = {
    # Oklab hue angles (degrees) of the sRGB hue families.
    "red": 25.0,
    "orange": 55.0,
    "yellow": 100.0,
    "green": 140.0,
    "aqua": 195.0,
    "blue": 255.0,
    "purple": 295.0,
    "magenta": 335.0,
}

# Skin in Oklab: hue roughly 40–85°, chroma 0.015–0.17 across the Monk scale.
SKIN_HUE_CENTER = 64.0
SKIN_HUE_HALF_WIDTH = 42.0
# Creative drift tolerated on skin before protection pulls it back.
SKIN_WARM_DRIFT = 6.0      # degrees toward yellow/orange
SKIN_COOL_DRIFT = 3.0      # degrees toward pink/magenta
SKIN_CHROMA_RANGE = (0.86, 1.14)  # chroma ratio band vs. the original


@dataclass
class Tint:
    hue: float = 0.0
    amount: float = 0.0


@dataclass
class Look:
    id: str
    name: str
    collection: str
    description: str = ""
    temperature: float = 0.0
    tint: float = 0.0
    exposure: float = 0.0
    highlight_rolloff: float = 0.35
    contrast: float = 0.0
    pivot: float = 0.45
    curve: list | None = None
    curve_r: list | None = None
    curve_g: list | None = None
    curve_b: list | None = None
    black: float = 0.0
    white: float = 1.0
    saturation: float = 1.0
    vibrance: float = 0.0
    hue_sat: dict = field(default_factory=dict)
    hue_shift: dict = field(default_factory=dict)
    hue_light: dict = field(default_factory=dict)
    shadow_tint: Tint = field(default_factory=Tint)
    highlight_tint: Tint = field(default_factory=Tint)
    split_balance: float = 0.0
    shadow_desat: float = 0.0
    highlight_desat: float = 0.0
    skin_protect: float = 0.75
    monochrome: bool = False
    mono_tone: Tint = field(default_factory=Tint)

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "Look":
        d = dict(d)
        for key in ("shadow_tint", "highlight_tint", "mono_tone"):
            if key in d:
                d[key] = Tint(**d[key])
        known = set(Look.__dataclass_fields__)
        unknown = set(d) - known
        if unknown:
            raise ValueError(f"look {d.get('id')}: unknown parameter(s) {sorted(unknown)}")
        return Look(**d)


# --------------------------------------------------------------------------
# The transform


def _hue_weights(h: np.ndarray) -> dict[str, np.ndarray]:
    """Smooth partition of unity over the hue circle (raised-cosine bands)."""
    names = list(HUE_BANDS)
    raw = {}
    for name in names:
        d = np.abs(hue_delta(h, HUE_BANDS[name]))
        width = 55.0
        raw[name] = np.where(d < width, 0.5 + 0.5 * np.cos(np.pi * d / width), 0.0)
    total = sum(raw.values()) + 1e-9
    return {k: v / total for k, v in raw.items()}


def _band_value(weights: dict[str, np.ndarray], table: dict, default: float) -> np.ndarray:
    out = np.zeros_like(next(iter(weights.values()))) + 0.0
    for name, w in weights.items():
        out = out + w * float(table.get(name, default))
    return out


def _gamut_map(L: np.ndarray, C: np.ndarray, h: np.ndarray) -> np.ndarray:
    """Reduce chroma (constant L and hue) until the colour fits in sRGB."""
    L = np.clip(L, 0.0, 1.0)
    rgb = oklab_to_linear(lch_to_lab(L, C, h))
    eps = 1e-6
    bad = np.any((rgb < -eps) | (rgb > 1 + eps), axis=-1)
    if np.any(bad):
        lo = np.zeros(int(bad.sum()))
        hi = C[bad].copy()
        Lb, hb = L[bad], h[bad]
        for _ in range(22):
            mid = 0.5 * (lo + hi)
            test = oklab_to_linear(lch_to_lab(Lb, mid, hb))
            ok = np.all((test >= -eps) & (test <= 1 + eps), axis=-1)
            lo = np.where(ok, mid, lo)
            hi = np.where(ok, hi, mid)
        C = C.copy()
        C[bad] = lo
        rgb = oklab_to_linear(lch_to_lab(L, C, h))
    return np.clip(rgb, 0.0, 1.0)


def apply_look(look: Look, srgb: np.ndarray) -> np.ndarray:
    """Applies `look` to an (..., 3) array of sRGB-encoded values in [0, 1]."""
    shape = srgb.shape
    x = srgb.reshape(-1, 3).astype(np.float64)

    # 1–3: linear-light white balance and exposure.
    lin = srgb_to_linear(x)
    lin = lin @ white_balance_matrix(look.temperature, look.tint).T
    lin = lin * (2.0 ** look.exposure)

    # Reference for skin protection: the original input. Skin is allowed a
    # little creative drift from here, never a full colour cast.
    ref_L, ref_C, ref_h = lab_to_lch(linear_to_oklab(np.clip(srgb_to_linear(x), 0, None)))

    # 4: hue-preserving shoulder on max(R, G, B). Values below the knee pass
    # through untouched; above it they approach 1.0 asymptotically.
    r = float(np.clip(look.highlight_rolloff, 0.0, 1.0))
    if r > 0:
        knee = 1.0 - 0.55 * r
        peak = np.max(lin, axis=-1, keepdims=True)
        over = np.maximum(peak - knee, 0.0)
        span = 1.0 - knee
        mapped = knee + span * (1.0 - np.exp(-over / span))
        scale = np.where(peak > knee, mapped / np.maximum(peak, 1e-9), 1.0)
        lin = lin * scale
    lin = np.clip(lin, 0.0, None)

    # 5: tone shaping in display (gamma) space, per channel.
    v = linear_to_srgb(lin)
    if look.contrast:
        c = float(look.contrast)
        p = float(look.pivot)
        vc = np.clip(v, 0.0, 1.0)
        lower = p * (vc / p) ** 2
        upper = 1.0 - (1.0 - p) * ((1.0 - vc) / (1.0 - p)) ** 2
        s = np.where(vc < p, lower, upper)
        if c > 0:
            v = v + c * (s - vc)
        else:
            # Negative contrast: blend toward the inverse S (flatter mids).
            inv_lower = p * np.sqrt(np.clip(vc / p, 0, None))
            inv_upper = 1.0 - (1.0 - p) * np.sqrt(np.clip((1.0 - vc) / (1.0 - p), 0, None))
            inv = np.where(vc < p, inv_lower, inv_upper)
            v = v + (-c) * 0.5 * (inv - vc)
    if look.curve:
        v = monotone_curve(look.curve)(v)
    for ch, pts in enumerate((look.curve_r, look.curve_g, look.curve_b)):
        if pts:
            v[:, ch] = monotone_curve(pts)(v[:, ch])
    v = look.black + (look.white - look.black) * np.clip(v, 0.0, 1.0)

    # 6: perceptual colour work in OkLCh.
    lin = srgb_to_linear(v)
    L, C, h = lab_to_lch(linear_to_oklab(np.clip(lin, 0, None)))
    neutral_guard = smoothstep(0.0, 0.035, C)  # hue is meaningless near grey

    if look.monochrome:
        C = np.zeros_like(C)
        if look.mono_tone.amount:
            w = 4.0 * L * (1.0 - L)  # strongest in the midtones
            C = look.mono_tone.amount * w
            h = np.full_like(h, look.mono_tone.hue)
        rgb = _gamut_map(L, C, h)
        return linear_to_srgb(rgb).reshape(shape)

    C = C * look.saturation
    if look.vibrance:
        # Boost muted colours more than saturated ones.
        C = C * (1.0 + look.vibrance * (1.0 - smoothstep(0.0, 0.22, C)))

    weights = _hue_weights(h)
    sat = _band_value(weights, look.hue_sat, 1.0)
    shift = _band_value(weights, look.hue_shift, 0.0)
    light = _band_value(weights, look.hue_light, 0.0)
    C = C * (1.0 + (sat - 1.0) * neutral_guard)
    h = (h + shift * neutral_guard) % 360.0
    L = L + light * neutral_guard * smoothstep(0.0, 0.12, C) * 0.5

    # Shadow/highlight desaturation (film-like rolloff of colour).
    if look.shadow_desat:
        C = C * (1.0 - look.shadow_desat * (1.0 - smoothstep(0.0, 0.45, L)))
    if look.highlight_desat:
        C = C * (1.0 - look.highlight_desat * smoothstep(0.6, 1.0, L))

    # Split toning: add a chroma vector by tonal range (luminance neutral).
    a = C * np.cos(np.radians(h))
    b = C * np.sin(np.radians(h))
    bal = float(look.split_balance)
    mid = 0.5 + 0.25 * bal
    w_sh = 1.0 - smoothstep(0.0, mid + 0.15, L)
    w_hi = smoothstep(mid - 0.15, 1.0, L)

    # Skin weight, from the original colour so it is stable across looks.
    skin_hue_w = np.clip(1.0 - (np.abs(hue_delta(ref_h, SKIN_HUE_CENTER)) / SKIN_HUE_HALF_WIDTH) ** 4, 0.0, 1.0)
    skin_w = skin_hue_w * smoothstep(0.010, 0.032, ref_C) * (1.0 - smoothstep(0.18, 0.26, ref_C))
    skin_w = skin_w * smoothstep(0.18, 0.32, ref_L)  # ignore near-black
    protect = float(np.clip(look.skin_protect, 0.0, 1.0))

    for tint, wt in ((look.shadow_tint, w_sh), (look.highlight_tint, w_hi)):
        if tint.amount:
            # Tints sit lighter on skin so faces stay clean.
            k = tint.amount * wt * (1.0 - 0.6 * protect * skin_w)
            a = a + k * np.cos(np.radians(tint.hue))
            b = b + k * np.sin(np.radians(tint.hue))
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360.0

    # 7: skin protection. Pull hue back toward the reference and keep chroma
    # within a flattering band so skin never turns orange, magenta or grey.
    if protect > 0:
        k = protect * skin_w
        dh = hue_delta(h, ref_h)
        excess = np.where(dh > 0, np.maximum(dh - SKIN_WARM_DRIFT, 0.0), np.minimum(dh + SKIN_COOL_DRIFT, 0.0))
        h = (h - k * excess) % 360.0
        ratio = C / np.maximum(ref_C, 1e-6)
        target = np.clip(ratio, *SKIN_CHROMA_RANGE)
        C = C * (1.0 + k * (target / np.maximum(ratio, 1e-6) - 1.0))

    # 8: back to sRGB with gamut mapping.
    rgb = _gamut_map(L, C, h)
    return linear_to_srgb(rgb).reshape(shape)


# --------------------------------------------------------------------------
# Cube I/O and application


def identity_grid(n: int = 33) -> np.ndarray:
    """(n^3, 3) grid in .cube order: red fastest, then green, then blue."""
    v = np.linspace(0.0, 1.0, n)
    b, g, r = np.meshgrid(v, v, v, indexing="ij")
    return np.stack([r.ravel(), g.ravel(), b.ravel()], axis=-1)


def build_cube(look: Look, n: int = 33) -> np.ndarray:
    out = apply_look(look, identity_grid(n))
    return np.clip(out, 0.0, 1.0)


def format_cube(look: Look, cube: np.ndarray, n: int = 33) -> str:
    lines = [
        f'TITLE "{look.name}"',
        f"# Snapper look '{look.id}' ({look.collection}). Generated by tools/lutgen — edit looks.toml, not this file.",
        f"LUT_3D_SIZE {n}",
        "DOMAIN_MIN 0.0 0.0 0.0",
        "DOMAIN_MAX 1.0 1.0 1.0",
    ]
    rounded = np.round(cube, 4)
    lines.extend(f"{r:.4f} {g:.4f} {b:.4f}" for r, g, b in rounded)
    return "\n".join(lines) + "\n"


def parse_cube(text: str) -> tuple[int, np.ndarray]:
    size = None
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("TITLE") or line.startswith("DOMAIN"):
            continue
        if line.startswith("LUT_3D_SIZE"):
            size = int(line.split()[1])
            continue
        rows.append([float(t) for t in line.split()])
    if size is None:
        raise ValueError("missing LUT_3D_SIZE")
    data = np.array(rows, dtype=np.float64)
    if data.shape != (size ** 3, 3):
        raise ValueError(f"expected {size ** 3} rows, got {data.shape}")
    return size, data


def apply_cube(cube: np.ndarray, n: int, srgb: np.ndarray) -> np.ndarray:
    """Trilinear lookup, matching how Core Image samples a colour cube."""
    shape = srgb.shape
    p = np.clip(srgb.reshape(-1, 3), 0.0, 1.0) * (n - 1)
    i0 = np.minimum(np.floor(p).astype(np.int64), n - 2)
    f = p - i0
    lut = cube.reshape(n, n, n, 3)  # [b, g, r]
    out = np.zeros_like(p)
    for db in (0, 1):
        wb = f[:, 2] if db else 1 - f[:, 2]
        for dg in (0, 1):
            wg = f[:, 1] if dg else 1 - f[:, 1]
            for dr in (0, 1):
                wr = f[:, 0] if dr else 1 - f[:, 0]
                w = (wb * wg * wr)[:, None]
                out += w * lut[i0[:, 2] + db, i0[:, 1] + dg, i0[:, 0] + dr]
    return out.reshape(shape)
