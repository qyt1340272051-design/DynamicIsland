#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${CI_DERIVED_DATA_PATH:-/tmp/dynamic-island-ci-derived-data}"
RESULT_BUNDLE_PATH="${CI_RESULT_BUNDLE_PATH:-/tmp/dynamic-island-ci-results-$$/TestResults.xcresult}"

if [[ -e "$RESULT_BUNDLE_PATH" ]]; then
  printf 'Result bundle already exists: %s\n' "$RESULT_BUNDLE_PATH" >&2
  exit 2
fi

mkdir -p "$(dirname "$RESULT_BUNDLE_PATH")"

"$SCRIPT_DIR/validate-release-config.sh"

printf 'Running Dynamic Island tests...\n'
xcodebuild test \
  -project "$ROOT_DIR/DynamicIsland.xcodeproj" \
  -scheme "Dynamic Island" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  -parallel-testing-enabled NO

printf 'Building Dynamic Island in Release configuration...\n'
xcodebuild build \
  -project "$ROOT_DIR/DynamicIsland.xcodeproj" \
  -scheme "Dynamic Island" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH"

printf 'Tests and Release build passed.\n'
