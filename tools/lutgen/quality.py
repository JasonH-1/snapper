"""Objective quality gates for generated looks.

Every look is checked through its *cube* (trilinear lookup, as on device),
not through the analytic transform, so the gates see what users see.

Gates (fail = the look must not ship):
  tone      neutral ramp stays monotonic in every channel (no inversions)
  shadows   the darkest 10% of input keeps visible separation (no crush)
  highlights the brightest 10% keeps visible separation (no clipping)
  skin      Monk-scale skin tones at three exposures keep a natural hue and
            chroma: not pushed toward orange, magenta, or grey
  banding   smooth 8-bit gradients do not develop visible steps
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from engine import apply_cube, hue_delta, lab_to_lch, linear_to_oklab, linear_to_srgb, srgb_to_linear

# Monk Skin Tone Scale (Google, CC BY 4.0), as published sRGB hex values.
MONK_SCALE = [
    "#f6ede4", "#f3e7db", "#f7ead0", "#eadaba", "#d7bd96",
    "#a07e56", "#825c43", "#604134", "#3a312a", "#292420",
]

# Thresholds (Oklab units; 0.01 is roughly one just-noticeable difference).
# Skin hue is judged as a perceptual hue difference ΔH = 2·√(C₁C₂)·sin(Δh/2),
# so a few degrees on a pale, low-chroma tone is not over-counted.
SKIN_DH_MAGENTA_LIMIT = 0.011   # ΔH toward pink/magenta
SKIN_DH_ORANGE_LIMIT = 0.016    # ΔH toward yellow/orange
SKIN_CHROMA_GREY_RATIO = 0.68   # below this ratio (and a visible drop) = grey skin
SKIN_CHROMA_ORANGE_RATIO = 1.40  # above this ratio (and a visible gain) = fake tan
SKIN_CHROMA_MIN_DELTA = 0.016   # grey: ignore chroma losses smaller than this
SKIN_CHROMA_MAX_GAIN = 0.022    # orange: ignore chroma gains smaller than this
SHADOW_MIN_SEPARATION = 0.055   # Oklab L across input 0..10%
HIGHLIGHT_MIN_SEPARATION = 0.022  # Oklab L across input 90..100%
TONE_MAX_DIP = 0.0012           # tolerated ramp dip (a third of an 8-bit level)
BANDING_MAX_EXCESS = 0.012      # output step larger than the input step by this much
BANDING_MAX_GAIN = 3.2          # max local contrast gain along gradients


def hex_to_rgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


def oklab_of_srgb(srgb: np.ndarray) -> np.ndarray:
    return linear_to_oklab(np.clip(srgb_to_linear(np.clip(srgb, 0, 1)), 0, None))


@dataclass
class Report:
    look_id: str
    failures: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    stats: dict[str, float] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.failures


def check_tone(cube: np.ndarray, n: int, rep: Report) -> None:
    x = np.linspace(0.0, 1.0, 1024)
    ramp = np.stack([x, x, x], axis=-1)
    out = apply_cube(cube, n, ramp)
    d = np.diff(out, axis=0)
    if np.min(d) < -TONE_MAX_DIP:
        ch = "RGB"[int(np.argmin(np.min(d, axis=0)))]
        rep.failures.append(f"tone inversion in {ch} channel on the grey ramp")
    L = oklab_of_srgb(out)[:, 0]
    if np.min(np.diff(L)) < -TONE_MAX_DIP:
        rep.failures.append("lightness inversion on the grey ramp")

    lo = L[int(0.10 * 1023)] - L[0]
    hi = L[-1] - L[int(0.90 * 1023)]
    rep.stats["shadow_sep"] = round(float(lo), 4)
    rep.stats["highlight_sep"] = round(float(hi), 4)
    rep.stats["black_L"] = round(float(L[0]), 3)
    rep.stats["white_L"] = round(float(L[-1]), 3)
    if lo < SHADOW_MIN_SEPARATION:
        rep.failures.append(f"crushed shadows (separation {lo:.3f} < {SHADOW_MIN_SEPARATION})")
    if hi < HIGHLIGHT_MIN_SEPARATION:
        rep.failures.append(f"clipped highlights (separation {hi:.3f} < {HIGHLIGHT_MIN_SEPARATION})")
    # Very bottom: the first 4% of input must still move.
    if L[int(0.04 * 1023)] - L[0] < 0.018:
        rep.warnings.append("deepest shadows are very flat")


def check_skin(cube: np.ndarray, n: int, rep: Report, monochrome: bool = False) -> None:
    if monochrome:
        rep.stats.update({"skin_dh_min": 0.0, "skin_dh_max": 0.0, "skin_c_min": 0.0, "skin_c_max": 0.0})
        return
    tones = np.array([hex_to_rgb(h) for h in MONK_SCALE])
    worst = {"hue_min": 0.0, "hue_max": 0.0, "c_min": 9.0, "c_max": 0.0}
    issues = []
    for exposure, label in ((-0.8, "shadow"), (0.0, "mid"), (0.3, "lit")):
        src = linear_to_srgb(np.clip(srgb_to_linear(tones) * (2 ** exposure), 0, 1))
        out = apply_cube(cube, n, src)
        _, c_in, h_in = lab_to_lch(oklab_of_srgb(src))
        L_out, c_out, h_out = lab_to_lch(oklab_of_srgb(out))
        for i in range(len(tones)):
            if c_in[i] < 0.025 or L_out[i] < 0.25 or np.max(src[i]) > 0.995:
                continue  # skip near-neutral, near-black and clipped samples
            dh = float(hue_delta(h_out[i], h_in[i]))
            dH = 2.0 * np.sqrt(c_in[i] * c_out[i]) * np.sin(np.radians(dh) / 2.0)
            cr = float(c_out[i] / c_in[i])
            dc = float(c_out[i] - c_in[i])
            worst["hue_min"] = min(worst["hue_min"], dh)
            worst["hue_max"] = max(worst["hue_max"], dh)
            worst["c_min"] = min(worst["c_min"], cr)
            worst["c_max"] = max(worst["c_max"], cr)
            tag = f"Monk {i + 1} {label}"
            if dH < -SKIN_DH_MAGENTA_LIMIT and h_out[i] < 55.0:
                issues.append(f"skin toward magenta ({tag}: {dh:+.1f}°)")
            if dH > SKIN_DH_ORANGE_LIMIT:
                issues.append(f"skin toward orange ({tag}: {dh:+.1f}°)")
            if cr < SKIN_CHROMA_GREY_RATIO and -dc > SKIN_CHROMA_MIN_DELTA and label != "shadow":
                issues.append(f"grey skin ({tag}: chroma x{cr:.2f})")
            if cr > SKIN_CHROMA_ORANGE_RATIO and dc > SKIN_CHROMA_MAX_GAIN:
                issues.append(f"over-saturated skin ({tag}: chroma x{cr:.2f})")
    rep.stats.update({
        "skin_dh_min": round(worst["hue_min"], 1),
        "skin_dh_max": round(worst["hue_max"], 1),
        "skin_c_min": round(worst["c_min"], 2),
        "skin_c_max": round(worst["c_max"], 2),
    })
    rep.failures.extend(sorted(set(issues))[:4])


def _gradients() -> list[np.ndarray]:
    """Smooth 8-bit gradients that commonly reveal banding."""
    t = np.linspace(0.0, 1.0, 256)[:, None]
    pairs = [
        ("#000000", "#ffffff"),  # grey
        ("#1d3557", "#a8dadc"),  # dusk sky
        ("#4a90d9", "#e8f1fb"),  # day sky
        ("#3b2a20", "#f2d2bd"),  # skin shadow -> highlight
        ("#0b0b1a", "#ff3ea5"),  # neon magenta falloff
        ("#06141b", "#2ee6d6"),  # neon cyan falloff
        ("#1a1205", "#ffb000"),  # sodium amber falloff
        ("#203020", "#c8e6a0"),  # foliage
    ]
    grads = []
    for a, b in pairs:
        ca, cb = hex_to_rgb(a), hex_to_rgb(b)
        g = ca * (1 - t) + cb * t
        grads.append(np.round(g * 255) / 255)
    return grads


def check_banding(cube: np.ndarray, n: int, rep: Report) -> None:
    worst_excess, worst_gain = 0.0, 0.0
    for g in _gradients():
        out = np.round(apply_cube(cube, n, g) * 255) / 255
        lab_in = oklab_of_srgb(g)
        lab_out = oklab_of_srgb(out)
        din = np.linalg.norm(np.diff(lab_in, axis=0), axis=-1)
        dout = np.linalg.norm(np.diff(lab_out, axis=0), axis=-1)
        worst_excess = max(worst_excess, float(np.max(dout - din)))
        # Gain over a sliding window of 8 steps (single-step ratios are noisy).
        k = 8
        cin = np.convolve(din, np.ones(k), "valid")
        cout = np.convolve(dout, np.ones(k), "valid")
        valid = cin > 0.01
        if np.any(valid):
            worst_gain = max(worst_gain, float(np.max(cout[valid] / cin[valid])))
    rep.stats["band_step"] = round(worst_excess, 4)
    rep.stats["band_gain"] = round(worst_gain, 2)
    if worst_excess > BANDING_MAX_EXCESS:
        rep.failures.append(f"banding risk: step +{worst_excess:.3f} on a smooth gradient")
    if worst_gain > BANDING_MAX_GAIN:
        rep.failures.append(f"banding risk: local contrast gain x{worst_gain:.1f}")


def evaluate(look_id: str, cube: np.ndarray, n: int = 33, monochrome: bool = False) -> Report:
    rep = Report(look_id)
    check_tone(cube, n, rep)
    check_skin(cube, n, rep, monochrome)
    check_banding(cube, n, rep)
    return rep
