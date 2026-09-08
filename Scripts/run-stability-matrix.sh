#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${STABILITY_DERIVED_DATA_PATH:-/tmp/dynamic-island-stability-derived-data}"

printf 'Running P3 stability scenarios: Spaces, full screen, hidden menu bar, clamshell, and denied Music automation.\n'

xcodebuild test \
  -project "$ROOT_DIR/灵动岛.xcodeproj" \
  -scheme "灵动岛" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  -only-testing:"灵动岛Tests/IslandPanelWindowPolicyTests" \
  -only-testing:"灵动岛Tests/IslandPanelStabilityMonitorTests" \
  -only-testing:"灵动岛Tests/IslandPanelGeometryTests" \
  -only-testing:"灵动岛Tests/ScreenManagerTests" \
  -only-testing:"灵动岛Tests/ScreenSelectionPolicyTests" \
  -only-testing:"灵动岛Tests/MusicControlServiceTests" \
  -only-testing:"灵动岛Tests/IslandViewModelTests/testRefreshNowPlayingReportsAutomationPermissionDenial"

printf 'P3 stability matrix passed.\n'
