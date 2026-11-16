#!/usr/bin/env bash
# Builds NudgeAgent.app into ./build.
#
# Signing: by default the app is signed ad-hoc ("-"). macOS ties Accessibility and
# Screen Recording grants to the code signature, and an ad-hoc signature changes on
# every rebuild, so macOS forgets those grants after each build. To keep them, set
# SIGN_IDENTITY to a stable certificate, for example:
#   SIGN_IDENTITY="Apple Development: Jane Doe (TEAMID)" scripts/build-app.sh
# (list yours with: security find-identity -v -p codesigning)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/NudgeAgent.app"

echo "Building release binary..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NudgeAgent" "$APP/Contents/MacOS/NudgeAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable certificate so macOS keeps permissions across rebuilds.
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -v -p codesigning | grep -q "Apple Development"; then
  SIGN_IDENTITY="Apple Development"
fi
echo "Signing with identity: ${SIGN_IDENTITY:--} (ad-hoc if '-')"
if [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
  codesign --force --sign - --entitlements Resources/NudgeAgent.entitlements "$APP"
else
  # Same hardened runtime and entitlements as release builds, so local runs behave the same.
  codesign --force --options runtime --timestamp=none \
    --entitlements Resources/NudgeAgent.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi

echo "Done: $ROOT/$APP"
