#!/usr/bin/env bash
# Builds a release for GitHub: dist/Onword.zip and dist/Onword.zip.sha256.
#
#   scripts/release.sh                 # build only
#   scripts/release.sh --publish       # also create the GitHub release vX.Y.Z (needs `gh`)
#
# Release builds are ad-hoc signed so no personal signing identity ships inside the app.
# The asset names never change, so the installer can always fetch .../releases/latest/download/Onword.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

swift test
OUT_DIR=dist/build SIGN_IDENTITY=- scripts/build-app.sh
codesign --verify --deep --strict dist/build/Onword.app

rm -f dist/Onword.zip dist/Onword.zip.sha256
ditto -c -k --keepParent dist/build/Onword.app dist/Onword.zip
shasum -a 256 dist/Onword.zip | awk '{print $1}' > dist/Onword.zip.sha256
echo "Built dist/Onword.zip ($(du -h dist/Onword.zip | cut -f1)), sha256 $(cat dist/Onword.zip.sha256)"

if [[ "${1:-}" == "--publish" ]]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" dist/Onword.zip dist/Onword.zip.sha256 --clobber
    echo "Updated release $TAG"
  else
    gh release create "$TAG" dist/Onword.zip dist/Onword.zip.sha256 --title "Onword $VERSION" \
      --notes-file "${NOTES_FILE:-/dev/null}"
    echo "Published release $TAG"
  fi
fi
