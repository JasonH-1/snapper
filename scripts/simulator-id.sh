#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest iOS runtime.
set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            # Prefer the newest runtime, then a non-"e"/"SE" model for a typical screen.
            score = (version, "SE" not in d["name"], d["name"])
            if best is None or score > best[0]:
                best = (score, d["udid"], d["name"], runtime)
if best is None:
    sys.exit("No iPhone simulator available")
print(best[1])
print(f"Using {best[2]} ({best[3]})", file=sys.stderr)
'
