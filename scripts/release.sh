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
# Releases ship the Google sign-in client (Resources/GoogleOAuth.plist, git-ignored) so "Connect Google
# Calendar" works; set INCLUDE_GOOGLE_OAUTH=0 to leave it out. Until Google verifies the project, sign-in
# is limited to its test users (or shows Google's "unverified app" warning once published).
OUT_DIR=dist/build SIGN_IDENTITY=- SKIP_GOOGLE_OAUTH=$([[ "${INCLUDE_GOOGLE_OAUTH:-1}" == "1" ]] && echo 0 || echo 1) \
  scripts/build-app.sh
[[ -f dist/build/Onword.app/Contents/Resources/GoogleOAuth.plist ]] && echo "note: Google sign-in client INCLUDED in this release"
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
