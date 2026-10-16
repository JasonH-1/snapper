#!/usr/bin/env bash
# Fails if an xcodebuild log contains compiler, linker or asset warnings.
# Usage: scripts/check-warnings.sh build/xcodebuild.log
set -euo pipefail

log="${1:?usage: check-warnings.sh <xcodebuild log>}"

# Tool chatter that is not about this project's sources (and never shows in
# Xcode's issue navigator) is ignored.
warnings=$(grep -E '(^|[^a-zA-Z])warning: ' "$log" \
  | grep -vE 'appintentsmetadataprocessor|Metadata extraction skipped|xcodebuild\[[0-9]+:[0-9]+\] +warning|IDERunDestination|Using the first of multiple matching destinations' \
  | sort -u || true)

if [[ -n "${warnings}" ]]; then
  echo "::error::Build produced warnings:"
  echo "${warnings}"
  count=$(echo "${warnings}" | wc -l | tr -d ' ')
  echo "::error::${count} warning(s) found"
  exit 1
fi
echo "No warnings."
