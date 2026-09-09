#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${STABILITY_DERIVED_DATA_PATH:-/tmp/dynamic-island-stability-derived-data}"

printf 'Running P3 stability scenarios: Spaces, full screen, hidden menu bar, clamshell, and denied Music automation.\n'

xcodebuild test \
  -project "$ROOT_DIR/DynamicIsland.xcodeproj" \
  -scheme "Dynamic Island" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  -only-testing:"DynamicIslandTests/IslandPanelWindowPolicyTests" \
  -only-testing:"DynamicIslandTests/IslandPanelStabilityMonitorTests" \
  -only-testing:"DynamicIslandTests/IslandPanelGeometryTests" \
  -only-testing:"DynamicIslandTests/ScreenManagerTests" \
  -only-testing:"DynamicIslandTests/ScreenSelectionPolicyTests" \
  -only-testing:"DynamicIslandTests/MusicControlServiceTests" \
  -only-testing:"DynamicIslandTests/IslandViewModelTests/testRefreshNowPlayingReportsAutomationPermissionDenial"

printf 'P3 stability matrix passed.\n'
