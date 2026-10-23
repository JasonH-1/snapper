#!/usr/bin/env python3
"""Snapper look generator.

Looks are defined by parameters in looks.toml. This tool turns them into
33-point LUTs for the app (.snaplut, a compact binary form; see engine.py),
checks them against objective quality gates, and renders contact sheets for
review.

    python3 tools/lutgen/lutgen.py build    # write the LUTs (+ add new looks to the app manifest)
    python3 tools/lutgen/lutgen.py review   # contact sheets + report in filter-review/
    python3 tools/lutgen/lutgen.py verify   # CI: committed LUTs match looks.toml and pass the gates
    python3 tools/lutgen/lutgen.py check    # print the quality report
    python3 tools/lutgen/lutgen.py cube     # the LUTs as .cube text for other apps, in build/cubes/

Options: --only <look-id>[,<look-id>...] limits build/review/check/cube to some looks.
         --out <dir> writes cube's .cube files somewhere else.
"""
from __future__ import annotations

import argparse
import json
import sys
import tomllib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from engine import Look, apply_cube, build_cube, decode_lut, encode_lut, format_cube  # noqa: E402
from quality import Report, evaluate  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
LOOKS_FILE = Path(__file__).resolve().parent / "looks.toml"
LUT_DIR = ROOT / "Snapper/Resources/Filters/LUTs"
LUT_EXT = ".snaplut"
CUBE_DIR = ROOT / "build/cubes"
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


def lut_path(look_id: str) -> Path:
    return LUT_DIR / f"{look_id}{LUT_EXT}"


def read_lut(look_id: str) -> tuple[int, np.ndarray]:
    return decode_lut(lut_path(look_id).read_bytes())


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
    the app's source of truth and is meant to be edited by hand. The
    exceptions are `lut` and `effects`, which looks.toml owns and are
    rewritten every build.
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
            entry = {
                "id": lk.id,
                "name": lk.name,
                "collection": lk.collection,
                "lut": lut_path(lk.id).name,
                "tier": "premium",
            }
            # The camera swipes in manifest order, so a new look joins the
            # end of its own collection rather than the end of the list.
            same = [i for i, e in enumerate(manifest["looks"]) if e["collection"] == lk.collection]
            manifest["looks"].insert(same[-1] + 1 if same else len(manifest["looks"]), entry)
            added.append(lk.id)
    by_id = {lk.id: lk for lk in looks}
    for entry in manifest["looks"]:
        lk = by_id.get(entry["id"])
        if lk is None:
            continue
        entry["lut"] = lut_path(lk.id).name
        if lk.effects:
            entry["effects"] = lk.effects
        else:
            entry.pop("effects", None)
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    if added:
        print(f"added to manifest as premium: {', '.join(added)}")
    known = {lk.id for lk in looks}
    for entry in manifest["looks"]:
        if not (LUT_DIR / entry["lut"]).exists() and entry["id"] not in known:
            print(f"warning: manifest look '{entry['id']}' has no LUT file {entry['lut']}")


def reference_fixture(looks: list[Look]) -> dict:
    inputs = np.array(REFERENCE_INPUTS)
    fixture = {"inputs": REFERENCE_INPUTS, "looks": {}}
    for lk in looks:
        _, cube = read_lut(lk.id)
        out = apply_cube(cube, N, inputs)
        fixture["looks"][lk.id] = [[round(float(v), 4) for v in row] for row in out]
    return fixture


def cmd_build(args) -> int:
    collections, looks = load_config()
    LUT_DIR.mkdir(parents=True, exist_ok=True)
    reports = []
    for lk in select(looks, args.only):
        blob = encode_lut(build_cube(lk, N), N)
        lut_path(lk.id).write_bytes(blob)
        (LUT_DIR / f"{lk.id}.cube").unlink(missing_ok=True)  # the .snaplut replaces it
        _, shipped = decode_lut(blob)
        reports.append(evaluate(lk.id, shipped, N, lk.monochrome))
    print_report(reports)
    update_manifest(collections, looks)
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(json.dumps(reference_fixture(looks)) + "\n")
    return 0 if all(r.ok for r in reports) else 1


def cmd_check(args) -> int:
    _, looks = load_config()
    reports = []
    for lk in select(looks, args.only):
        _, cube = read_lut(lk.id)
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
    entries = {entry["id"]: entry for entry in manifest["looks"]}
    for lk in looks:
        if lk.id in entries and entries[lk.id].get("effects", {}) != lk.effects:
            problems.append(f"effects for '{lk.id}' in {MANIFEST.name} are stale — run lutgen.py build")
        if lk.id in entries and entries[lk.id]["lut"] != lut_path(lk.id).name:
            problems.append(f"'{lk.id}' in {MANIFEST.name} should use {lut_path(lk.id).name} — run lutgen.py build")
        if (LUT_DIR / f"{lk.id}.cube").exists():
            problems.append(f"{lk.id}.cube is left over next to {lut_path(lk.id).name} and would ship too — run lutgen.py build")
    for lk in looks:
        path = lut_path(lk.id)
        if not path.exists():
            problems.append(f"{path.name} missing — run lutgen.py build")
            continue
        try:
            n, committed = decode_lut(path.read_bytes())
        except ValueError as error:
            problems.append(f"{path.name} is unreadable ({error}) — run lutgen.py build")
            continue
        fresh = build_cube(lk, N)
        diff = float(np.max(np.abs(committed - fresh))) if n == N else float("inf")
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
    print(f"{len(looks)} looks verified: LUTs up to date, all quality gates pass.")
    return 0


def cmd_review(args) -> int:
    from review import render_review  # Pillow only needed here

    collections, looks = load_config()
    looks = select(looks, args.only)
    cubes = {}
    reports = {}
    for lk in looks:
        _, cube = read_lut(lk.id)
        cubes[lk.id] = cube
        reports[lk.id] = evaluate(lk.id, cube, N, lk.monochrome)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {"looks": []}
    tiers = {e["id"]: e.get("tier", "premium") for e in manifest["looks"]}
    render_review(collections, looks, cubes, reports, tiers, PHOTOS_DIR, REVIEW_DIR, N)
    return 0


def cmd_cube(args) -> int:
    """Writes the committed LUTs as .cube text, to open the looks in other apps."""
    _, looks = load_config()
    out = Path(args.out) if args.out else CUBE_DIR
    out.mkdir(parents=True, exist_ok=True)
    chosen = select(looks, args.only)
    for lk in chosen:
        n, cube = read_lut(lk.id)
        (out / f"{lk.id}.cube").write_text(format_cube(lk, cube, n))
    print(f"wrote {len(chosen)} .cube files to {out}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["build", "check", "verify", "review", "cube"])
    parser.add_argument("--only", help="comma-separated look ids")
    parser.add_argument("--out", help="output folder for cube (default build/cubes)")
    args = parser.parse_args()
    commands = {"build": cmd_build, "check": cmd_check, "verify": cmd_verify, "review": cmd_review, "cube": cmd_cube}
    return commands[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
