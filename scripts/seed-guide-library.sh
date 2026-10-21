#!/bin/zsh
# Fills the Simulator's Snapper Library with the 12 photos the Guide's clips
# expect (SnapperDemos/GuideDemoTests.swift), in their order. All are free to
# use without credit or a model release: the Unsplash photos in
# Snapper/Resources/Showcase and crops of them (not the portrait), and three
# CC0 / public-domain photos from test-photos/stand-ins.
#
#   SIMULATOR_ID=<device id> scripts/seed-guide-library.sh
#
# Snapper's current Library is moved to build/guide-demos/library-<time>.
# PHOTOS=1 also adds the photos to the Simulator's Photos library, which the
# import picker in guide-library shows; it should hold nothing else.
set -euo pipefail

root=${0:A:h:h}
device=${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}')}
bundle=${APP_BUNDLE_ID:-com.example.snapper}
showcase="$root/Snapper/Resources/Showcase"
stand_ins="$root/test-photos/stand-ins"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Crops: height width y x.
cp "$showcase/showcase-cake.jpg" "$work/cake.jpg"
cp "$stand_ins/food-coffee.jpg" "$work/coffee.jpg"
sips -c 1080 1190 --cropOffset 690 1 "$showcase/showcase-beach.jpg" --out "$work/beach-rock.jpg" > /dev/null
sips -c 1000 750 --cropOffset 300 600 "$showcase/showcase-cafe.jpg" --out "$work/cafe-window.jpg" > /dev/null
cp "$showcase/showcase-arcade.jpg" "$work/arcade.jpg"
cp "$showcase/showcase-night.jpg" "$work/night.jpg"
cp "$showcase/showcase-beach.jpg" "$work/beach.jpg"
cp "$stand_ins/pet-cat.jpg" "$work/cat.jpg"
cp "$stand_ins/outdoor-launch.jpg" "$work/launch.jpg"
sips -c 900 1196 --cropOffset 60 0 "$showcase/showcase-night.jpg" --out "$work/night-lights.jpg" > /dev/null
cp "$showcase/showcase-cafe.jpg" "$work/cafe.jpg"
sips -c 600 650 --cropOffset 0 700 "$showcase/showcase-arcade.jpg" --out "$work/arcade-signs.jpg" > /dev/null

captures="$(xcrun simctl get_app_container "$device" "$bundle" data)/Library/Application Support/Captures"
xcrun simctl terminate "$device" "$bundle" 2> /dev/null || true
if [[ -d "$captures" ]]; then
  backup="$root/build/guide-demos/library-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${backup:h}"
  mv "$captures" "$backup"
  echo "Moved the old Library to $backup"
fi
mkdir -p "$captures"

# Newest first, as the Library shows them. Photo 0 is painted in
# guide-selective, 4 keeps its Midnight look, 5 is the one most clips edit,
# 5–7 are styled together in guide-batch.
python3 - "$work" "$captures" <<'PY'
import json, os, shutil, sys, time, uuid
work, captures = sys.argv[1:]
now = time.time() - 978307200  # Foundation dates count from 2001
day = 86400
# File, source, look it arrived with, look it has now, days since it joined
# the Library, days since an import was taken.
photos = [
    ("cake", "camera", "pocket", None, 0.15, None),
    ("coffee", "camera", "instant", None, 0.2, None),
    ("beach-rock", "imported", "original", "boardwalk", 1.3, 40),
    ("cafe-window", "imported", "original", "cream", 1.3, 41),
    ("arcade", "imported", "original", "midnight", 1.3, 55),
    ("night", "imported", "original", None, 1.3, 62),
    ("beach", "imported", "original", None, 1.3, 90),
    ("cat", "imported", "original", None, 1.3, 120),
    ("launch", "imported", "original", None, 1.3, 300),
    ("night-lights", "camera", "afterglow", None, 3.4, None),
    ("cafe", "camera", "silver", None, 3.5, None),
    ("arcade-signs", "camera", "signal", None, 5.6, None),
]

def recipe(look):
    tone = {k: 0 for k in ["brightness", "contrast", "saturation", "warmth", "highlights", "shadows",
                           "fade", "vignette", "grain", "bloom", "halation"]}
    zero = {"brightness": 0, "saturation": 0, "warmth": 0}
    return {"lookID": look, "strength": 1,
            "adjustments": {**tone, "colorMixer": {"bands": {}}},
            "crop": {"shape": "original", "isFlipped": False, "straighten": 0, "quarterTurns": 0},
            "selective": {"subject": zero, "background": zero},
            "finish": {"border": 0.05, "frame": "none", "layout": "original"}}

records = []
for i, (name, source, initial, current, joined, taken) in enumerate(photos):
    id = str(uuid.uuid4()).upper()
    shutil.copy(os.path.join(work, name + ".jpg"), os.path.join(captures, id + ".jpg"))
    record = {"id": id, "createdAt": now - joined * day - i * 0.001, "fileName": id + ".jpg",
              "source": source, "isFrontCamera": False,
              "recipe": recipe(current or initial), "initialRecipe": recipe(initial)}
    if taken:
        record["takenAt"] = now - taken * day
    records.append(record)
json.dump(records, open(os.path.join(captures, "captures.json"), "w"))
print(f"Wrote {len(records)} photos to Snapper's Library")
PY

if [[ -n ${PHOTOS:-} ]]; then
  xcrun simctl addmedia "$device" "$work"/{launch,cat,beach,arcade,cafe-window,beach-rock,night,cafe,coffee,cake,night-lights}.jpg
  echo "Added 11 photos to the Simulator's Photos library"
fi
