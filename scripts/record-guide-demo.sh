#!/bin/zsh
# Records one of the guide's demo clips from the Simulator.
#
#   scripts/record-guide-demo.sh <test name> <topic id>
#   scripts/record-guide-demo.sh testColorMixer color-mixer
#
# Runs SnapperDemos/GuideDemoTests/<test name> while the Simulator records,
# keeps only the part between its "DEMO START" and "DEMO END" marks, and
# writes Snapper/Resources/GuideDemos/guide-<topic id>.mp4 with the camera
# moves and holds the test marked (see encode-guide-demo.swift). The guide
# shows that clip in place of the topic's sample. OUTPUT=<file> writes it
# elsewhere (the website's clips go in docs/). FRAMES=<dir> also writes
# review stills there.
#
# SIMULATOR_ID picks the device (default: the first booted iPhone).
# DERIVED_DATA reuses a build folder between runs.
set -euo pipefail

test_name=${1:?usage: record-guide-demo.sh <test name> <topic id>}
topic=${2:?usage: record-guide-demo.sh <test name> <topic id>}
root=${0:A:h:h}
device=${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}')}
derived=${DERIVED_DATA:-$root/build/guide-demos}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
destination="platform=iOS Simulator,id=$device"
output=${OUTPUT:-$root/Snapper/Resources/GuideDemos/guide-$topic.mp4}
[[ $output = /* ]] || output="$root/$output"

cd "$root"
xcodegen generate --quiet
xcodebuild -project Snapper.xcodeproj -scheme SnapperGuideDemos -destination "$destination" \
  -derivedDataPath "$derived" build-for-testing -quiet

# A tidy status bar: 9:41, full battery and signal.
xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 --dataNetwork wifi

xcrun simctl io "$device" recordVideo --codec=h264 --force "$work/raw.mp4" 2> "$work/record.log" &
recorder=$!
# Recording starts once it says so; note the time to line it up with the test.
for _ in {1..50}; do grep -q "Recording started" "$work/record.log" 2>/dev/null && break; sleep 0.1; done
recording_started=$(python3 -c 'import time; print(time.time())')

xcodebuild -project Snapper.xcodeproj -scheme SnapperGuideDemos -destination "$destination" \
  -derivedDataPath "$derived" test-without-building -collect-test-diagnostics never \
  -only-testing:"SnapperDemos/GuideDemoTests/$test_name" > "$work/test.log" 2>&1 || {
    kill -INT $recorder; wait $recorder || true
    xcrun simctl status_bar "$device" clear
    # Keep the recording and the whole log to see what went wrong.
    mkdir -p "$derived/failed"
    cp "$work/raw.mp4" "$derived/failed/$topic.mp4" 2>/dev/null || true
    cp "$work/test.log" "$derived/failed/$topic.log"
    grep -m3 "error:" "$work/test.log"; exit 1
  }

kill -INT $recorder
wait $recorder || true
xcrun simctl status_bar "$device" clear

# "t = 0.00s Start Test at <date>" gives the test's clock; the marks are
# offsets from it. They become times in the recording for the encoder.
python3 - "$work/test.log" "$recording_started" > "$work/marks" <<'PY'
import re, sys
from datetime import datetime
log = open(sys.argv[1]).read()
began = re.search(r"Start Test at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", log)
marks = re.findall(r"t =\s+([\d.]+)s ((?:DEMO START|DEMO END|SCREEN|CAMERA|HOLD)\b[^\n]*)", log)
names = [name.strip() for _, name in marks]
if not began or "DEMO START" not in names or "DEMO END" not in names:
    sys.exit("No DEMO START / DEMO END marks in the test log")
offset = datetime.strptime(began.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() - float(sys.argv[2])
for t, name in marks:
    print(f"{offset + float(t):.3f} {name.strip()}")
PY
read start duration < <(awk '$2 == "DEMO" && $3 == "START" { s = $1 } $2 == "DEMO" && $3 == "END" { e = $1 }
  END { s -= 0.1; if (s < 0) s = 0; printf "%.2f %.2f\n", s, e - s + 0.2 }' "$work/marks")

# Keep the raw recording and its trim points, to re-encode without re-recording.
mkdir -p "${output:h}" "$derived/raw"
cp "$work/raw.mp4" "$derived/raw/$topic.mp4"
cp "$work/marks" "$derived/raw/$topic.marks"
echo "$start $duration" > "$derived/raw/$topic.trim"
encoder="$derived/encode-guide-demo"
if [[ ! -x "$encoder" || "$root/scripts/encode-guide-demo.swift" -nt "$encoder" ]]; then
  swiftc -O -parse-as-library -swift-version 5 -suppress-warnings "$root/scripts/encode-guide-demo.swift" -o "$encoder"
fi
"$encoder" "$work/raw.mp4" "$output" "$start" "$duration" "$work/marks" ${FRAMES:-}
