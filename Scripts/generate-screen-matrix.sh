#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${SCREEN_MATRIX_DERIVED_DATA_PATH:-/tmp/dynamic-island-screen-matrix-derived-data}"

if [[ -n "${SCREEN_MATRIX_OUTPUT_DIR:-}" ]]; then
  OUTPUT_DIR="$SCREEN_MATRIX_OUTPUT_DIR"
  if [[ "$OUTPUT_DIR" != /* ]]; then
    printf 'SCREEN_MATRIX_OUTPUT_DIR must be an absolute path.\n' >&2
    exit 1
  fi
  if [[ -L "$OUTPUT_DIR" || ( -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ) ]]; then
    printf 'Output path must be a directory, not a symlink or file: %s\n' "$OUTPUT_DIR" >&2
    exit 1
  fi
  if [[ -d "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -print -quit)" ]]; then
    printf 'Output directory must be empty; existing output was preserved: %s\n' "$OUTPUT_DIR" >&2
    exit 1
  fi
  mkdir -p "$OUTPUT_DIR"
else
  OUTPUT_ROOT="$ROOT_DIR/artifacts/screen-matrix"
  mkdir -p "$OUTPUT_ROOT"
  OUTPUT_DIR="$(mktemp -d "$OUTPUT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
fi

export SCREEN_MATRIX_OUTPUT_DIR="$OUTPUT_DIR"
export TEST_RUNNER_SCREEN_MATRIX_OUTPUT_DIR="$OUTPUT_DIR"

xcodebuild test \
  -project "$ROOT_DIR/DynamicIsland.xcodeproj" \
  -scheme "Screen Matrix" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  -only-testing:"DynamicIslandTests/ScreenSnapshotMatrixTests/testGenerateSnapshotMatrix" \
  ENABLE_APP_SANDBOX=NO \
  CODE_SIGN_ENTITLEMENTS=

SNAPSHOT_COUNT="$(python3 - "$OUTPUT_DIR" <<'PY'
import json
from pathlib import Path, PurePosixPath
import struct
import sys

output = Path(sys.argv[1]).resolve()
manifest_path = output / "manifest.json"
if not manifest_path.is_file():
    sys.exit(f"Snapshot manifest was not generated: {manifest_path}")
try:
    manifest = json.loads(manifest_path.read_text())
except (OSError, ValueError) as error:
    sys.exit(f"Cannot read snapshot manifest: {error}")

count = manifest.get("snapshotCount")
records = manifest.get("snapshots")
if type(count) is not int or count <= 0 or not isinstance(records, list) or len(records) != count:
    sys.exit("Manifest snapshotCount must match its nonempty snapshots list.")

listed = set()
for record in records:
    filename = record.get("file") if isinstance(record, dict) else None
    if not isinstance(filename, str) or not filename:
        sys.exit("Every manifest snapshot must name a PNG file.")
    relative = PurePosixPath(filename)
    if relative.is_absolute() or ".." in relative.parts or relative.suffix != ".png":
        sys.exit(f"Invalid manifest PNG path: {filename}")
    if filename in listed:
        sys.exit(f"Duplicate manifest PNG path: {filename}")
    listed.add(filename)
    path = output / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(output):
        sys.exit(f"Manifest PNG is missing or outside the output directory: {filename}")
    with path.open("rb") as image:
        header = image.read(24)
    if (len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n"
            or header[12:16] != b"IHDR" or not all(struct.unpack(">II", header[16:24]))):
        sys.exit(f"Manifest file does not have a valid PNG header: {filename}")

actual = {path.relative_to(output).as_posix() for path in output.rglob("*")
          if path.is_file() and path.suffix.lower() == ".png"}
if actual != listed:
    sys.exit(f"PNG files do not match manifest; missing={sorted(listed - actual)}, "
             f"unlisted={sorted(actual - listed)}")
print(count)
PY
)"

printf 'Generated %s snapshots.\n' "$SNAPSHOT_COUNT"
printf 'Open %s/index.html to review the matrix.\n' "$OUTPUT_DIR"
