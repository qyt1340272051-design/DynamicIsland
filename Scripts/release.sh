#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/DynamicIsland.xcodeproj"
SCHEME="Dynamic Island"
APP_NAME="Dynamic Island"
BUNDLE_IDENTIFIER="com.rong5.dynamic-island-mac"
MODE=""
RELEASE_TAG="${RELEASE_TAG:-}"
OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$ROOT_DIR/build/release}"
MOUNT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/release.sh --local [--output <directory>]
  ./Scripts/release.sh --release <tag> [--output <directory>]

Modes:
  --local          Build an ad hoc signed archive and DMG for pipeline testing.
                   This artifact is not notarized and must not be distributed.
  --release <tag>  Build, Developer ID sign, notarize, staple, and verify a DMG.

Formal release environment:
  APPLE_TEAM_ID
  NOTARYTOOL_PROFILE

Instead of NOTARYTOOL_PROFILE, provide either:
  APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD
or:
  APPLE_API_KEY_PATH, APPLE_API_KEY_ID, and optional APPLE_API_ISSUER_ID
EOF
}

fail() {
  printf 'Release failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      [[ -z "$MODE" ]] || fail "choose exactly one release mode"
      MODE="local"
      shift
      ;;
    --release)
      [[ -z "$MODE" ]] || fail "choose exactly one release mode"
      [[ $# -ge 2 ]] || fail "--release requires a tag"
      MODE="release"
      RELEASE_TAG="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a directory"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument '$1'"
      ;;
  esac
done

[[ -n "$MODE" ]] || {
  usage >&2
  exit 2
}

for command in xcodebuild codesign hdiutil lipo plutil shasum ditto; do
  command -v "$command" >/dev/null || fail "required command '$command' is unavailable"
done

"$SCRIPT_DIR/validate-release-config.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dynamic-island-release.XXXXXX")"
BUILD_SETTINGS_PATH="$WORK_DIR/build-settings.txt"
ARCHIVE_PATH="$WORK_DIR/DynamicIsland.xcarchive"
DERIVED_DATA_PATH="$WORK_DIR/DerivedData"
EXPORT_PATH="$WORK_DIR/Export"
STAGING_PATH="$WORK_DIR/DiskImage"
NOTARY_RESULT_PATH="$WORK_DIR/notary-result.json"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -showBuildSettings > "$BUILD_SETTINGS_PATH"

read_setting() {
  local key="$1"
  awk -v key="$key" '$1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }' "$BUILD_SETTINGS_PATH"
}

MARKETING_VERSION="$(read_setting MARKETING_VERSION)"
BUILD_NUMBER="$(read_setting CURRENT_PROJECT_VERSION)"
[[ -n "$MARKETING_VERSION" ]] || fail "MARKETING_VERSION is unavailable"
[[ -n "$BUILD_NUMBER" ]] || fail "CURRENT_PROJECT_VERSION is unavailable"

if [[ -z "$RELEASE_TAG" ]]; then
  RELEASE_TAG="v${MARKETING_VERSION}-beta.1"
fi

if [[ ! "$RELEASE_TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
  fail "tag '$RELEASE_TAG' is not valid semantic version syntax"
fi

TAG_MARKETING_VERSION="${BASH_REMATCH[1]}"
[[ "$TAG_MARKETING_VERSION" == "$MARKETING_VERSION" ]] || \
  fail "tag version '$TAG_MARKETING_VERSION' does not match MARKETING_VERSION '$MARKETING_VERSION'"

VERSION_LABEL="${RELEASE_TAG#v}"
ARTIFACT_SUFFIX=""

ARCHIVE_ARGUMENTS=(
  archive
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  ONLY_ACTIVE_ARCH=NO
  "ARCHS=arm64 x86_64"
)

if [[ "$MODE" == "release" ]]; then
  [[ -n "${APPLE_TEAM_ID:-}" ]] || fail "APPLE_TEAM_ID is required for a formal release"

  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
    fail "formal releases require a clean working tree"
  fi

  TAG_COMMIT="$(git -C "$ROOT_DIR" rev-list -n 1 "$RELEASE_TAG" 2>/dev/null || true)"
  HEAD_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  [[ -n "$TAG_COMMIT" ]] || fail "tag '$RELEASE_TAG' does not exist"
  [[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] || fail "tag '$RELEASE_TAG' does not point to HEAD"

  if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    SIGNING_IDENTITY="$DEVELOPER_ID_APPLICATION"
  else
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | \
      grep 'Developer ID Application:' | grep "(${APPLE_TEAM_ID})" | \
      head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  fi
  [[ -n "$SIGNING_IDENTITY" ]] || \
    fail "no Developer ID Application identity for team '$APPLE_TEAM_ID' was found"

  NOTARY_ARGUMENTS=()
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    NOTARY_ARGUMENTS=(--keychain-profile "$NOTARYTOOL_PROFILE")
  elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" ]]; then
    NOTARY_ARGUMENTS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID")
    if [[ -n "${APPLE_API_ISSUER_ID:-}" ]]; then
      NOTARY_ARGUMENTS+=(--issuer "$APPLE_API_ISSUER_ID")
    fi
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    NOTARY_ARGUMENTS=(
      --apple-id "$APPLE_ID"
      --password "$APPLE_APP_SPECIFIC_PASSWORD"
      --team-id "$APPLE_TEAM_ID"
    )
  else
    fail "provide NOTARYTOOL_PROFILE, App Store Connect API credentials, or Apple ID notarization credentials"
  fi

  ARCHIVE_ARGUMENTS+=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
    "DEVELOPMENT_TEAM=$APPLE_TEAM_ID"
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
else
  SIGNING_IDENTITY="-"
  ARTIFACT_SUFFIX="-local"
  ARCHIVE_ARGUMENTS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
    DEVELOPMENT_TEAM=
  )
  printf 'Local mode creates a non-notarized artifact for pipeline testing only.\n'
fi

printf 'Archiving %s %s (%s)...\n' "$APP_NAME" "$MARKETING_VERSION" "$RELEASE_TAG"
xcodebuild "${ARCHIVE_ARGUMENTS[@]}"

ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[[ -d "$ARCHIVED_APP_PATH" ]] || fail "archive does not contain '$APP_NAME.app'"

if [[ "$MODE" == "release" ]]; then
  EXPORT_OPTIONS_PATH="$WORK_DIR/ExportOptions.plist"
  plutil -create xml1 "$EXPORT_OPTIONS_PATH"
  plutil -insert method -string developer-id "$EXPORT_OPTIONS_PATH"
  plutil -insert destination -string export "$EXPORT_OPTIONS_PATH"
  plutil -insert signingStyle -string manual "$EXPORT_OPTIONS_PATH"
  plutil -insert signingCertificate -string "$SIGNING_IDENTITY" "$EXPORT_OPTIONS_PATH"
  plutil -insert teamID -string "$APPLE_TEAM_ID" "$EXPORT_OPTIONS_PATH"
  plutil -insert stripSwiftSymbols -bool YES "$EXPORT_OPTIONS_PATH"

  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH"
else
  mkdir -p "$EXPORT_PATH"
  ditto "$ARCHIVED_APP_PATH" "$EXPORT_PATH/$APP_NAME.app"
fi

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST_PATH" ]] || fail "exported app Info.plist is missing"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST_PATH")"
APP_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST_PATH")"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST_PATH")"
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST_PATH")"

[[ "$APP_VERSION" == "$MARKETING_VERSION" ]] || fail "exported app version is '$APP_VERSION'"
[[ "$APP_BUILD" == "$BUILD_NUMBER" ]] || fail "exported app build is '$APP_BUILD'"
[[ "$APP_DISPLAY_NAME" == "$APP_NAME" ]] || fail "exported display name is '$APP_DISPLAY_NAME'"
[[ "$APP_BUNDLE_ID" == "$BUNDLE_IDENTIFIER" ]] || fail "exported bundle ID is '$APP_BUNDLE_ID'"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
CODESIGN_INFO="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
printf '%s\n' "$CODESIGN_INFO" | grep -Eq 'flags=.*runtime' || fail "Hardened Runtime flag is missing"

ENTITLEMENTS_PATH="$WORK_DIR/exported-entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PATH" 2>/dev/null
GET_TASK_ALLOW="$(plutil -extract com.apple.security.get-task-allow raw "$ENTITLEMENTS_PATH" 2>/dev/null || true)"
[[ "$GET_TASK_ALLOW" != "true" && "$GET_TASK_ALLOW" != "1" ]] || \
  fail "distribution app contains com.apple.security.get-task-allow"

if [[ "$MODE" == "release" ]]; then
  printf '%s\n' "$CODESIGN_INFO" | grep -Fq 'Authority=Developer ID Application:' || \
    fail "exported app is not signed with Developer ID Application"
  printf '%s\n' "$CODESIGN_INFO" | grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" || \
    fail "exported app TeamIdentifier does not match APPLE_TEAM_ID"
fi

APP_ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE")"
for architecture in arm64 x86_64; do
  printf '%s\n' "$APP_ARCHITECTURES" | grep -qw "$architecture" || \
    fail "exported app is missing architecture '$architecture'"
done

mkdir -p "$STAGING_PATH"
ditto "$APP_PATH" "$STAGING_PATH/$APP_NAME.app"
ln -s /Applications "$STAGING_PATH/Applications"

DMG_PATH="$OUTPUT_DIR/Dynamic-Island-${VERSION_LABEL}${ARTIFACT_SUFFIX}.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
MANIFEST_PATH="$OUTPUT_DIR/Dynamic-Island-${VERSION_LABEL}${ARTIFACT_SUFFIX}.json"
rm -f "$DMG_PATH" "$CHECKSUM_PATH" "$MANIFEST_PATH"

printf 'Creating %s...\n' "$(basename "$DMG_PATH")"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [[ "$MODE" == "release" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --strict --verbose=2 "$DMG_PATH"

  printf 'Submitting DMG to Apple notary service...\n'
  xcrun notarytool submit "$DMG_PATH" \
    "${NOTARY_ARGUMENTS[@]}" \
    --wait \
    --output-format json > "$NOTARY_RESULT_PATH"

  NOTARY_STATUS="$(plutil -extract status raw "$NOTARY_RESULT_PATH")"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    SUBMISSION_ID="$(plutil -extract id raw "$NOTARY_RESULT_PATH" 2>/dev/null || true)"
    if [[ -n "$SUBMISSION_ID" ]]; then
      xcrun notarytool log "$SUBMISSION_ID" \
        "${NOTARY_ARGUMENTS[@]}" \
        "$OUTPUT_DIR/notary-${SUBMISSION_ID}.json" || true
    fi
    fail "notary service returned '$NOTARY_STATUS'"
  fi

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

MOUNT_DIR="$WORK_DIR/MountedDMG"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet
[[ -d "$MOUNT_DIR/$APP_NAME.app" ]] || fail "DMG does not contain '$APP_NAME.app'"

if [[ "$MODE" == "release" ]]; then
  spctl --assess --type execute --verbose=2 "$MOUNT_DIR/$APP_NAME.app"
fi

hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)
SHA256="$(awk '{ print $1 }' "$CHECKSUM_PATH")"

MANIFEST_PLIST_PATH="$WORK_DIR/release-manifest.plist"
plutil -create xml1 "$MANIFEST_PLIST_PATH"
plutil -insert product -string "$APP_NAME" "$MANIFEST_PLIST_PATH"
plutil -insert tag -string "$RELEASE_TAG" "$MANIFEST_PLIST_PATH"
plutil -insert bundleIdentifier -string "$APP_BUNDLE_ID" "$MANIFEST_PLIST_PATH"
plutil -insert marketingVersion -string "$APP_VERSION" "$MANIFEST_PLIST_PATH"
plutil -insert buildNumber -string "$APP_BUILD" "$MANIFEST_PLIST_PATH"
plutil -insert architectures -string "$APP_ARCHITECTURES" "$MANIFEST_PLIST_PATH"
plutil -insert notarized -bool "$([[ "$MODE" == "release" ]] && printf YES || printf NO)" "$MANIFEST_PLIST_PATH"
plutil -insert artifact -string "$(basename "$DMG_PATH")" "$MANIFEST_PLIST_PATH"
plutil -insert sha256 -string "$SHA256" "$MANIFEST_PLIST_PATH"
plutil -convert json -o "$MANIFEST_PATH" "$MANIFEST_PLIST_PATH"

printf '\nRelease artifact verification passed.\n'
printf 'DMG: %s\n' "$DMG_PATH"
printf 'SHA-256: %s\n' "$SHA256"
printf 'Manifest: %s\n' "$MANIFEST_PATH"
if [[ "$MODE" == "local" ]]; then
  printf 'This local artifact is not notarized and must not be published.\n'
fi
