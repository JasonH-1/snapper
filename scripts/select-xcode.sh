#!/usr/bin/env bash
# Selects the newest non-beta Xcode installed on a GitHub macOS runner.
set -euo pipefail

echo "Installed Xcode versions:"
ls -d /Applications/Xcode*.app || true

candidate=$(ls -d /Applications/Xcode_*.app 2>/dev/null \
  | grep -viE 'beta|_rc|release_candidate' \
  | sed -E 's#^/Applications/Xcode_(.*)\.app$#\1#' \
  | sort -t. -k1,1n -k2,2n -k3,3n \
  | tail -1 || true)

if [[ -n "${candidate}" ]]; then
  sudo xcode-select -s "/Applications/Xcode_${candidate}.app"
fi
xcodebuild -version
