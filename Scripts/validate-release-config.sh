#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/DynamicIsland.xcodeproj"
SCHEME="Dynamic Island"
EXPECTED_VERSION="0.4.0"
OLD_PROJECT_NAME="$(printf '\347\201\265\345\212\250\345\262\233')"

fail() {
  printf 'Release configuration error: %s\n' "$1" >&2
  exit 1
}

read_setting() {
  local key="$1"
  awk -v key="$key" '$1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }' "$BUILD_SETTINGS_PATH"
}

assert_setting() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(read_setting "$key")"
  [[ "$actual" == "$expected" ]] || fail "$key must be '$expected' (found '$actual')"
}

[[ -d "$PROJECT_PATH" ]] || fail "DynamicIsland.xcodeproj is missing"
[[ -d "$ROOT_DIR/DynamicIsland" ]] || fail "DynamicIsland source directory is missing"
[[ -d "$ROOT_DIR/DynamicIslandTests" ]] || fail "DynamicIslandTests directory is missing"
[[ -f "$ROOT_DIR/DynamicIsland/DynamicIsland.entitlements" ]] || fail "release entitlements are missing"

if git -C "$ROOT_DIR" grep -n "$OLD_PROJECT_NAME" -- .; then
  fail "the previous Chinese project name is still present in tracked files"
fi

PROJECT_LIST_PATH="$(mktemp "${TMPDIR:-/tmp}/dynamic-island-project-list.XXXXXX")"
BUILD_SETTINGS_PATH="$(mktemp "${TMPDIR:-/tmp}/dynamic-island-build-settings.XXXXXX")"
trap 'rm -f "$PROJECT_LIST_PATH" "$BUILD_SETTINGS_PATH"' EXIT

xcodebuild -list -project "$PROJECT_PATH" > "$PROJECT_LIST_PATH"
grep -Fq "Dynamic Island" "$PROJECT_LIST_PATH" || fail "Dynamic Island target or scheme is missing"
grep -Fq "DynamicIslandTests" "$PROJECT_LIST_PATH" || fail "DynamicIslandTests target is missing"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -showBuildSettings > "$BUILD_SETTINGS_PATH"

assert_setting PRODUCT_NAME "Dynamic Island"
assert_setting PRODUCT_MODULE_NAME DynamicIsland
assert_setting MARKETING_VERSION "$EXPECTED_VERSION"
assert_setting CURRENT_PROJECT_VERSION 1
assert_setting ENABLE_HARDENED_RUNTIME YES
assert_setting CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO
assert_setting CODE_SIGN_ENTITLEMENTS DynamicIsland/DynamicIsland.entitlements
assert_setting INFOPLIST_KEY_CFBundleDisplayName "Dynamic Island"
assert_setting INFOPLIST_KEY_LSApplicationCategoryType public.app-category.utilities

plutil -lint "$ROOT_DIR/DynamicIsland/DynamicIsland.entitlements" >/dev/null

for script in "$SCRIPT_DIR"/*.sh; do
  bash -n "$script"
done

printf 'Release configuration is valid for Dynamic Island %s.\n' "$EXPECTED_VERSION"
