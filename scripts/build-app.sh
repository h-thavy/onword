#!/usr/bin/env bash
# Builds build/Onword.app from the Swift package.
#
#   scripts/build-app.sh                              # signs with your first "Apple Development" identity
#   SIGN_IDENTITY="Onword Dev" scripts/build-app.sh  # or any identity from: security find-identity -v -p codesigning
#   SIGN_IDENTITY=- scripts/build-app.sh               # ad-hoc (permissions reset on every rebuild)
#   OUT_DIR=dist/build scripts/build-app.sh            # build somewhere other than build/
#
# A real identity matters: macOS ties Accessibility / Input Monitoring grants to the signature.
# With a stable identity they survive rebuilds; ad-hoc signatures change every build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development|Developer ID Application|Onword Dev/ { print $2; exit }')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
OUT_DIR="${OUT_DIR:-build}"
APP="$OUT_DIR/Onword.app"

swift build -c "$CONFIG" --product Onword
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Onword" "$APP/Contents/MacOS/Onword"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift
# Google sign-in for "Connect Google Calendar" (git-ignored; see Resources/GoogleOAuth.example.plist).
# Releases include it unless INCLUDE_GOOGLE_OAUTH=0 (see scripts/release.sh).
if [[ -f Resources/GoogleOAuth.plist && "${SKIP_GOOGLE_OAUTH:-0}" != "1" ]]; then
  cp Resources/GoogleOAuth.plist "$APP/Contents/Resources/GoogleOAuth.plist"
else
  echo "note: Resources/GoogleOAuth.plist not found; 'Connect Google Calendar' will be unavailable in this build"
fi

# SwiftPM resource bundles from dependencies (if any) go in Contents/Resources.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" \
  --entitlements Resources/Onword.entitlements "$APP"

# Register the fresh bundle with LaunchServices (dev builds only; releases are registered by the installer). Without this, System Settings can't resolve
# io.github.h-thavy.onword to an app and hides it from the Privacy lists, even when access is granted.
if [[ "$OUT_DIR" == "build" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

echo "Built $APP (signed with: $SIGN_IDENTITY)"
