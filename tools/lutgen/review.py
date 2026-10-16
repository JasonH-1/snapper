"""Contact sheets and the review report in filter-review/.

One sheet per collection: rows are looks (with "Original" on top), columns
are the photos in test-photos/ followed by the synthetic charts. Every cell
is produced through the look's .cube with trilinear lookup, like the app.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from charts import CHARTS
from engine import Look, apply_cube
from quality import Report

CELL_W, CELL_H = 300, 228
LABEL_W = 250
HEADER_H = 92
COL_HEADER_H = 34
GAP = 6
BG = (18, 18, 20)
CELL_BG = (32, 32, 36)
TEXT = (236, 236, 240)
MUTED = (150, 150, 160)
GOOD = (110, 200, 140)
BAD = (240, 110, 100)
FREE = (255, 193, 94)

FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/inter/Inter-SemiBold.otf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/Library/Fonts/Arial.ttf",
]
FONT_REGULAR_CANDIDATES = [
    "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/Library/Fonts/Arial.ttf",
]


def _font(size: int, bold: bool = True) -> ImageFont.ImageFont:
    for path in FONT_CANDIDATES if bold else FONT_REGULAR_CANDIDATES:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def load_sources(photos_dir: Path) -> list[tuple[str, np.ndarray]]:
    sources = []
    exts = {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff", ".webp"}
    files = sorted(p for p in photos_dir.rglob("*") if p.suffix.lower() in exts)
    for p in files:
        try:
            im = Image.open(p)
            im = im.convert("RGB")
        except Exception as exc:  # unreadable (e.g. HEIC without a plugin)
            print(f"skipping {p.name}: {exc}")
            continue
        im.thumbnail((CELL_W * 2, CELL_H * 2), Image.LANCZOS)
        sources.append((p.stem, np.asarray(im, dtype=np.float64) / 255.0))
    for name, fn in CHARTS.items():
        sources.append((name, fn(CELL_W * 2, CELL_H * 2)))
    return sources


def _fit(arr: np.ndarray) -> Image.Image:
    im = Image.fromarray(np.clip(arr * 255 + 0.5, 0, 255).astype(np.uint8))
    im.thumbnail((CELL_W, CELL_H), Image.LANCZOS)
    cell = Image.new("RGB", (CELL_W, CELL_H), CELL_BG)
    cell.paste(im, ((CELL_W - im.width) // 2, (CELL_H - im.height) // 2))
    return cell


def _label(draw: ImageDraw.ImageDraw, x: int, y: int, title: str, lines: list[tuple[str, tuple]]):
    draw.text((x, y), title, font=_font(24), fill=TEXT)
    yy = y + 34
    for text, color in lines:
        draw.text((x, yy), text, font=_font(15, bold=False), fill=color)
        yy += 21


def render_sheet(collection_id: str, collection: dict, looks: list[Look], cubes: dict,
                 reports: dict, tiers: dict, sources, out: Path, n: int) -> None:
    cols = len(sources)
    rows = len(looks) + 1
    width = LABEL_W + cols * (CELL_W + GAP) + GAP
    height = HEADER_H + COL_HEADER_H + rows * (CELL_H + GAP) + GAP
    sheet = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(sheet)
    draw.text((24, 18), collection["name"], font=_font(40), fill=TEXT)
    draw.text((26, 64), collection.get("tagline", ""), font=_font(17, bold=False), fill=MUTED)

    y0 = HEADER_H
    for c, (name, _) in enumerate(sources):
        x = LABEL_W + GAP + c * (CELL_W + GAP)
        draw.text((x + 4, y0 + 6), name, font=_font(15, bold=False), fill=MUTED)

    y = HEADER_H + COL_HEADER_H
    # Original row.
    _label(draw, 20, y + 12, "Original", [("unfiltered reference", MUTED)])
    for c, (_, arr) in enumerate(sources):
        sheet.paste(_fit(arr), (LABEL_W + GAP + c * (CELL_W + GAP), y))
    y += CELL_H + GAP

    for lk in looks:
        rep: Report = reports[lk.id]
        tier = tiers.get(lk.id, "premium")
        lines = [
            (f"{lk.id} · {tier.upper()}", FREE if tier == "free" else MUTED),
            ("✓ quality gates" if rep.ok else "✗ " + rep.failures[0][:26], GOOD if rep.ok else BAD),
        ]
        desc = lk.description
        while desc and len(lines) < 7:
            cut = desc[:27]
            if len(desc) > 27 and " " in cut:
                cut = cut[:cut.rindex(" ")]
            lines.append((cut, MUTED))
            desc = desc[len(cut):].lstrip()
        _label(draw, 20, y + 12, lk.name, lines)
        for c, (_, arr) in enumerate(sources):
            out_arr = apply_cube(cubes[lk.id], n, arr)
            sheet.paste(_fit(out_arr), (LABEL_W + GAP + c * (CELL_W + GAP), y))
        y += CELL_H + GAP

    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, quality=88, optimize=True)
    print(f"wrote {out}")


def write_report(collections: dict, looks: list[Look], reports: dict, tiers: dict, out_dir: Path,
                 sheet_names: dict) -> None:
    lines = [
        "# Filter review",
        "",
        "Contact sheets for every look, rendered through the exact `.cube` files the app ships.",
        "Each sheet shows one style direction: rows are looks, columns are the photos in",
        "`test-photos/` plus three synthetic charts (skin tones, colour checker + gradients, neon night).",
        "",
        "To approve or reject, edit the **Verdict** column below (or just tell me which looks to drop).",
        "Regenerate after changing `tools/lutgen/looks.toml` or adding photos:",
        "",
        "```sh",
        "python3 tools/lutgen/lutgen.py build    # rewrite the .cube files",
        "python3 tools/lutgen/lutgen.py review   # rewrite these sheets",
        "```",
        "",
        "Quality gates (all must pass to ship): monotonic tone, no crushed shadows, no clipped",
        "highlights, natural skin across the Monk scale (no orange, magenta or grey shift), and no",
        "banding on smooth 8-bit gradients. The numbers are explained in `tools/lutgen/quality.py`.",
        "",
    ]
    for cid, c in collections.items():
        group = [lk for lk in looks if lk.collection == cid]
        if not group:
            continue
        lines += [
            f"## {c['name']}",
            "",
            f"_{c.get('tagline', '')}_",
            "",
            f"![{c['name']}]({sheet_names[cid]})",
            "",
            "| Look | Tier | Gates | Shadows | Highlights | Skin hue shift | Skin chroma | Verdict |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for lk in group:
            r = reports[lk.id]
            s = r.stats
            gates = "✅" if r.ok else "❌ " + "; ".join(r.failures)
            lines.append(
                f"| **{lk.name}** — {lk.description} | {tiers.get(lk.id, 'premium')} | {gates} | "
                f"{s['shadow_sep']:.3f} | {s['highlight_sep']:.3f} | {s['skin_dh_min']:+.1f}° … {s['skin_dh_max']:+.1f}° | "
                f"×{s['skin_c_min']:.2f} … ×{s['skin_c_max']:.2f} |  |"
            )
        lines.append("")
    (out_dir / "README.md").write_text("\n".join(lines) + "\n")
    print(f"wrote {out_dir / 'README.md'}")


def render_review(collections, looks, cubes, reports, tiers, photos_dir: Path, out_dir: Path, n: int) -> None:
    sources = load_sources(photos_dir)
    sheet_names = {}
    for cid, c in collections.items():
        group = [lk for lk in looks if lk.collection == cid]
        if not group:
            continue
        name = f"{cid}.jpg"
        sheet_names[cid] = name
        render_sheet(cid, c, group, cubes, reports, tiers, sources, out_dir / name, n)
    write_report(collections, looks, reports, tiers, out_dir, sheet_names)
