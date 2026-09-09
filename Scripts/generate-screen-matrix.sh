#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/artifacts/screen-matrix"
DERIVED_DATA_PATH="${SCREEN_MATRIX_DERIVED_DATA_PATH:-/tmp/dynamic-island-screen-matrix-derived-data}"

mkdir -p "$(dirname "$OUTPUT_DIR")"

xcodebuild test \
  -project "$ROOT_DIR/DynamicIsland.xcodeproj" \
  -scheme "Screen Matrix" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  -only-testing:"DynamicIslandTests/ScreenSnapshotMatrixTests/testGenerateSnapshotMatrix" \
  ENABLE_APP_SANDBOX=NO \
  CODE_SIGN_ENTITLEMENTS=

SNAPSHOT_COUNT="$(find "$OUTPUT_DIR" -type f -name '*.png' | wc -l | tr -d ' ')"
if [[ "$SNAPSHOT_COUNT" != "64" ]]; then
  printf 'Expected 64 snapshots, found %s.\n' "$SNAPSHOT_COUNT" >&2
  exit 1
fi

printf 'Generated %s snapshots.\n' "$SNAPSHOT_COUNT"
printf 'Open %s/index.html to review the matrix.\n' "$OUTPUT_DIR"
