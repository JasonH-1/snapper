"""Texture-and-light effects a look adds on top of its colour cube.

A cube only maps colours, so glow, colour fringing, scanlines and the like are
drawn by the app (Snapper/Filters/LookPipeline+Effects.swift) after the cube.
They are not part of the .cube files, the quality gates or the contact
sheets: review them in the app. `lutgen.py build` validates each look's
`effects`, fills in the defaults below and writes them to filters.json.

Lengths are fractions of the image's shorter side, so the live preview, the
review screen and a full-resolution export look the same.
"""
from __future__ import annotations

from typing import Any

DEFAULTS: dict[str, dict[str, float]] = {
    # A graduated filter from the top edge (Lightroom's linear gradient),
    # usually for sky: brightens by `exposure` stops and pulls towards
    # `tint_hue` (Oklab degrees, as for shadow_tint) by `tint` (0..1), fading
    # out at `size` of the height.
    "gradient": {"size": 0.5, "exposure": 0.4, "tint_hue": 240, "tint": 0.3},
    # Bright, saturated light (signs, screens) blooms in its own colour.
    # threshold: brightness 0..1 where the glow starts. tint (0..1) pulls the
    # glow towards tint_hue (Oklab degrees), e.g. cyan halos around white lamps.
    "glow": {"threshold": 0.6, "radius": 0.02, "intensity": 0.7, "saturation": 1.4, "tint_hue": 0, "tint": 0},
    # Film halation: a red-orange halo around bright light (light bouncing
    # off the film base through the red-sensitive layer; never blue).
    "halation": {"threshold": 0.7, "radius": 0.012, "intensity": 0.6},
    # Lens colour fringing: red and blue drift apart towards the edges.
    # amount: how far (as a scale factor) the channels separate at the edge.
    "chromatic_aberration": {"amount": 0.003},
    # Videotape colour smear: colour bleeds sideways, brightness stays sharp.
    "chroma_bleed": {"radius": 0.012},
    # Digital glitch: a red/blue split plus horizontal slices pushed sideways.
    # shift: largest slice offset as a fraction of the image width.
    "glitch": {"slices": 6, "shift": 0.03, "rgb_split": 0.004},
    # Film burn: full-height bands of light from the left/right edges that
    # streak along the film and burn red → orange → yellow where strongest.
    # Edges, band count, widths and peaks come from each photo's seed.
    # size: band width as a fraction of the image width; tint_hue sets the
    # burn's middle colour (Oklab degrees).
    "light_leak": {"intensity": 0.6, "size": 0.45, "tint_hue": 45},
    # Dark horizontal lines, like a CRT or a paused tape.
    "scanlines": {"spacing": 0.006, "intensity": 0.22},
    # Fine luminance noise; size is one noise cell.
    "noise": {"amount": 0.12, "size": 0.0012},
    # Film grain: clumpy (roughness 0..1), strongest in mid-tones and shadows,
    # mostly grey (color 0..1 adds colour grain).
    "grain": {"amount": 0.25, "size": 0.0012, "roughness": 0.5, "color": 0.15},
    # Darkened corners; radius is a fraction of the half-diagonal.
    "vignette": {"intensity": 0.5, "radius": 0.9},
}

_INTEGER_PARAMS = {("glitch", "slices")}


def normalize_effects(look_id: str | None, raw: Any) -> dict[str, dict[str, float | int]]:
    """Validates a look's `effects` table and fills in every default.

    Returns the effects in a stable order, exactly as the app reads them.
    """
    if not isinstance(raw, dict):
        raise ValueError(f"look {look_id}: effects must be a table")
    effects: dict[str, dict[str, float | int]] = {}
    for name, params in raw.items():
        if name not in DEFAULTS:
            raise ValueError(f"look {look_id}: unknown effect '{name}' (known: {', '.join(DEFAULTS)})")
        if not isinstance(params, dict):
            raise ValueError(f"look {look_id}: effects.{name} must be a table")
        unknown = set(params) - set(DEFAULTS[name])
        if unknown:
            raise ValueError(f"look {look_id}: unknown effects.{name} parameter(s) {sorted(unknown)}")
        merged: dict[str, float | int] = {}
        for key, default in DEFAULTS[name].items():
            value = params.get(key, default)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
                raise ValueError(f"look {look_id}: effects.{name}.{key} must be a number ≥ 0")
            merged[key] = int(value) if (name, key) in _INTEGER_PARAMS else float(value)
        effects[name] = merged
    return {name: effects[name] for name in DEFAULTS if name in effects}
