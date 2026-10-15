#!/usr/bin/env python3
"""Snapper look generator.

Looks are defined by parameters in looks.toml. This tool turns them into
33-point .cube files for the app, checks them against objective quality
gates, and renders contact sheets for review.

    python3 tools/lutgen/lutgen.py build    # write .cube files (+ add new looks to the app manifest)
    python3 tools/lutgen/lutgen.py review   # contact sheets + report in filter-review/
    python3 tools/lutgen/lutgen.py verify   # CI: committed cubes match looks.toml and pass the gates
    python3 tools/lutgen/lutgen.py check    # print the quality report

Options: --only <look-id>[,<look-id>...] limits build/review/check to some looks.
"""
from __future__ import annotations

import argparse
import json
import sys
import tomllib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from engine import Look, apply_cube, build_cube, format_cube, parse_cube  # noqa: E402
from quality import Report, evaluate  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
LOOKS_FILE = Path(__file__).resolve().parent / "looks.toml"
LUT_DIR = ROOT / "Snapper/Resources/Filters/LUTs"
MANIFEST = ROOT / "Snapper/Resources/Filters/filters.json"
REVIEW_DIR = ROOT / "filter-review"
FIXTURE = ROOT / "SnapperTests/Fixtures/lut-reference.json"

# Colours sampled into the unit-test fixture: the app renders these through
# Core Image and must match the Python reference within a small tolerance.
REFERENCE_INPUTS = [
    [0.0, 0.0, 0.0], [0.18, 0.18, 0.18], [0.5, 0.5, 0.5], [0.85, 0.85, 0.85], [1.0, 1.0, 1.0],
    [0.92, 0.76, 0.66], [0.63, 0.47, 0.34], [0.36, 0.25, 0.20],
    [0.80, 0.20, 0.20], [0.20, 0.60, 0.25], [0.25, 0.45, 0.85], [0.95, 0.80, 0.20],
    [0.45, 0.70, 0.90], [0.70, 0.35, 0.75], [0.10, 0.15, 0.30], [0.30, 0.55, 0.50],
]
PHOTOS_DIR = ROOT / "test-photos"
N = 33


def load_config() -> tuple[dict, list[Look]]:
    with open(LOOKS_FILE, "rb") as f:
        cfg = tomllib.load(f)
    collections = cfg.get("collections", {})
    looks = [Look.from_dict(d) for d in cfg.get("look", [])]
    ids = [lk.id for lk in looks]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        sys.exit(f"duplicate look ids: {sorted(dupes)}")
    for lk in looks:
        if lk.collection not in collections:
            sys.exit(f"look {lk.id}: unknown collection '{lk.collection}'")
    return collections, looks


def select(looks: list[Look], only: str | None) -> list[Look]:
    if not only:
        return looks
    wanted = set(only.split(","))
    chosen = [lk for lk in looks if lk.id in wanted]
    missing = wanted - {lk.id for lk in chosen}
    if missing:
        sys.exit(f"unknown look id(s): {sorted(missing)}")
    return chosen


def print_report(reports: list[Report]) -> None:
    for rep in reports:
        status = "PASS" if rep.ok else "FAIL"
        s = rep.stats
        print(f"{status}  {rep.look_id:<14} shadows {s['shadow_sep']:.3f}  highlights {s['highlight_sep']:.3f}  "
              f"skin hue {s['skin_dh_min']:+.1f}..{s['skin_dh_max']:+.1f}°  chroma x{s['skin_c_min']:.2f}..x{s['skin_c_max']:.2f}  "
              f"band {s['band_step']:.3f}/x{s['band_gain']:.1f}")
        for f in rep.failures:
            print(f"      ✗ {f}")
        for w in rep.warnings:
            print(f"      ! {w}")


def update_manifest(collections: dict, looks: list[Look]) -> None:
    """Adds looks/collections that are missing from the app manifest.

    Existing entries (order, names, tiers) are never changed: the manifest is
    the app's source of truth and is meant to be edited by hand.
    """
    if MANIFEST.exists():
        manifest = json.loads(MANIFEST.read_text())
    else:
        manifest = {"version": 1, "collections": [], "looks": []}
    have_c = {c["id"] for c in manifest["collections"]}
    for cid, c in collections.items():
        if cid not in have_c:
            manifest["collections"].append({"id": cid, "name": c["name"], "tagline": c.get("tagline", "")})
    have_l = {entry["id"] for entry in manifest["looks"]}
    added = []
    for lk in looks:
        if lk.id not in have_l:
            manifest["looks"].append({
                "id": lk.id,
                "name": lk.name,
                "collection": lk.collection,
                "lut": f"{lk.id}.cube",
                "tier": "premium",
            })
            added.append(lk.id)
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    if added:
        print(f"added to manifest as premium: {', '.join(added)}")
    known = {lk.id for lk in looks}
    for entry in manifest["looks"]:
        if not (LUT_DIR / entry["lut"]).exists() and entry["id"] not in known:
            print(f"warning: manifest look '{entry['id']}' has no cube file {entry['lut']}")


def reference_fixture(looks: list[Look]) -> dict:
    inputs = np.array(REFERENCE_INPUTS)
    fixture = {"inputs": REFERENCE_INPUTS, "looks": {}}
    for lk in looks:
        _, cube = parse_cube((LUT_DIR / f"{lk.id}.cube").read_text())
        out = apply_cube(cube, N, inputs)
        fixture["looks"][lk.id] = [[round(float(v), 4) for v in row] for row in out]
    return fixture


def cmd_build(args) -> int:
    collections, looks = load_config()
    LUT_DIR.mkdir(parents=True, exist_ok=True)
    reports = []
    for lk in select(looks, args.only):
        cube = build_cube(lk, N)
        (LUT_DIR / f"{lk.id}.cube").write_text(format_cube(lk, cube, N))
        reports.append(evaluate(lk.id, np.round(cube, 4), N, lk.monochrome))
    print_report(reports)
    update_manifest(collections, looks)
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(json.dumps(reference_fixture(looks)) + "\n")
    return 0 if all(r.ok for r in reports) else 1


def cmd_check(args) -> int:
    _, looks = load_config()
    reports = []
    for lk in select(looks, args.only):
        _, cube = parse_cube((LUT_DIR / f"{lk.id}.cube").read_text())
        reports.append(evaluate(lk.id, cube, N, lk.monochrome))
    print_report(reports)
    return 0 if all(r.ok for r in reports) else 1


def cmd_verify(args) -> int:
    _, looks = load_config()
    problems = []
    manifest = json.loads(MANIFEST.read_text())
    for entry in manifest["looks"]:
        if not (LUT_DIR / entry["lut"]).exists():
            problems.append(f"manifest look '{entry['id']}' points to missing {entry['lut']}")
    for lk in looks:
        path = LUT_DIR / f"{lk.id}.cube"
        if not path.exists():
            problems.append(f"{path.name} missing — run lutgen.py build")
            continue
        n, committed = parse_cube(path.read_text())
        fresh = np.round(build_cube(lk, N), 4)
        diff = float(np.max(np.abs(committed - fresh)))
        if n != N or diff > 6e-4:
            problems.append(f"{path.name} is stale (max diff {diff:.4f}) — run lutgen.py build")
        rep = evaluate(lk.id, committed, n, lk.monochrome)
        if not rep.ok:
            problems.append(f"{lk.id} fails quality gates: {'; '.join(rep.failures)}")
    if not problems:
        committed_fixture = json.loads(FIXTURE.read_text()) if FIXTURE.exists() else None
        if committed_fixture != json.loads(json.dumps(reference_fixture(looks))):
            problems.append(f"{FIXTURE.relative_to(ROOT)} is stale — run lutgen.py build")
    if problems:
        print("\n".join(problems))
        return 1
    print(f"{len(looks)} looks verified: cubes up to date, all quality gates pass.")
    return 0


def cmd_review(args) -> int:
    from review import render_review  # Pillow only needed here

    collections, looks = load_config()
    looks = select(looks, args.only)
    cubes = {}
    reports = {}
    for lk in looks:
        path = LUT_DIR / f"{lk.id}.cube"
        _, cube = parse_cube(path.read_text())
        cubes[lk.id] = cube
        reports[lk.id] = evaluate(lk.id, cube, N, lk.monochrome)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {"looks": []}
    tiers = {e["id"]: e.get("tier", "premium") for e in manifest["looks"]}
    render_review(collections, looks, cubes, reports, tiers, PHOTOS_DIR, REVIEW_DIR, N)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["build", "check", "verify", "review"])
    parser.add_argument("--only", help="comma-separated look ids")
    args = parser.parse_args()
    return {"build": cmd_build, "check": cmd_check, "verify": cmd_verify, "review": cmd_review}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
