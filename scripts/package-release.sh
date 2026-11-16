#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) NudgeAgent.app and packs it into a DMG
# (drag-to-Applications window) for a GitHub release.
#
# Unsigned test build (ad-hoc, users must click "Open Anyway"):
#   scripts/package-release.sh
#
# Trusted build (Developer ID signature + Apple notarization):
#   SIGN_IDENTITY="Developer ID Application" NOTARY_PROFILE=nudgeagent scripts/package-release.sh
#
# One-time setup for the trusted build:
#   1. Create a "Developer ID Application" certificate (Xcode > Settings > Accounts >
#      Manage Certificates > + ). It lands in your login Keychain.
#   2. Create an App Store Connect API key (Users and Access > Integrations > Team Keys,
#      role "Developer"), download the .p8, then store it in the Keychain once:
#        xcrun notarytool store-credentials nudgeagent \
#          --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
#      After that you can delete the .p8 file. Nothing secret is stored in this repo.
#
# Output: build/NudgeAgent-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="build/NudgeAgent.app"
DMG="build/NudgeAgent-${VERSION}.dmg"
IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="Resources/NudgeAgent.entitlements"

echo "Building arm64..."
swift build -c release --triple arm64-apple-macosx14.0
echo "Building x86_64..."
swift build -c release --triple x86_64-apple-macosx14.0

echo "Assembling universal $APP..."
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  .build/arm64-apple-macosx/release/NudgeAgent \
  .build/x86_64-apple-macosx/release/NudgeAgent \
  -output "$APP/Contents/MacOS/NudgeAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ "$IDENTITY" == "-" ]]; then
  echo "Signing ad-hoc (not trusted on other Macs)"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "Signing with \"$IDENTITY\" (hardened runtime, secure timestamp)"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "Creating DMG..."
STAGE="build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "NudgeAgent ${VERSION}" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
rm -rf "$STAGE"

if [[ "$IDENTITY" != "-" ]]; then
  echo "Signing the DMG..."
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$IDENTITY" != Developer\ ID\ Application* ]]; then
    echo "Notarization needs SIGN_IDENTITY to be a \"Developer ID Application\" certificate." >&2
    exit 1
  fi
  echo "Submitting the DMG to Apple for notarization (usually a few minutes)..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "Stapling the notarization ticket to the DMG..."
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  echo "NOTARY_PROFILE not set: skipping notarization (macOS will warn on first launch)."
fi

lipo -archs "$APP/Contents/MacOS/NudgeAgent"
echo "Done: $ROOT/$DMG"
