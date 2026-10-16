#!/usr/bin/env bash
# Runs xcodebuild with the full log written to a file and a readable summary on
# stdout. Usage: scripts/xcb.sh <log file> <xcodebuild args...>
set -uo pipefail

log="$1"; shift
mkdir -p "$(dirname "$log")"
xcodebuild "$@" > "$log" 2>&1
status=$?

grep -E '(error|warning): |Test Case .* (passed|failed)|Executed [0-9]+ test|\*\* .* \*\*' "$log" | sort -u | head -400 || true
if [[ $status -ne 0 ]]; then
  echo "---- last 80 lines of $log ----"
  tail -80 "$log"
fi
exit $status
