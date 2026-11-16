#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) NudgeAgent.app and zips it for a GitHub release.
#
#   scripts/package-release.sh            -> build/NudgeAgent-<version>.zip
#
# Signing: ad-hoc by default ("-"). Set SIGN_IDENTITY to a Developer ID certificate to
# sign properly; notarization is not done here, so downloaded builds still need the
# "Open Anyway" step described in the README.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="build/NudgeAgent.app"
ZIP="build/NudgeAgent-${VERSION}.zip"

echo "Building arm64..."
swift build -c release --triple arm64-apple-macosx14.0
echo "Building x86_64..."
swift build -c release --triple x86_64-apple-macosx14.0

echo "Assembling universal $APP..."
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  .build/arm64-apple-macosx/release/NudgeAgent \
  .build/x86_64-apple-macosx/release/NudgeAgent \
  -output "$APP/Contents/MacOS/NudgeAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "Signing with identity: ${SIGN_IDENTITY:--} (ad-hoc if '-')"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=1 "$APP"

echo "Zipping..."
ditto -c -k --keepParent "$APP" "$ZIP"
lipo -archs "$APP/Contents/MacOS/NudgeAgent"
echo "Done: $ROOT/$ZIP"
