#!/usr/bin/env bash
# Builds a release for GitHub: dist/Onword.zip and dist/Onword.zip.sha256.
#
#   scripts/release.sh                 # build only
#   scripts/release.sh --publish       # also create the GitHub release vX.Y.Z (needs `gh`)
#
# Releases are signed with the "Onword Release" certificate (self-made, no personal details) so every
# version has the same identity: macOS keeps Accessibility, Input Monitoring and the Keychain item across
# updates. Its keychain and password live outside the repo, in ONWORD_SIGNING_DIR (default
# ../onword-backups/signing). Without it the build falls back to ad-hoc signing, with a warning.
# The asset names never change, so the installer can always fetch .../releases/latest/download/Onword.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

swift test
# Releases ship the Google sign-in client (Resources/GoogleOAuth.plist, git-ignored) so "Connect Google
# Calendar" works; set INCLUDE_GOOGLE_OAUTH=0 to leave it out. Until Google verifies the project, sign-in
# is limited to its test users (or shows Google's "unverified app" warning once published).
SIGNING_DIR="${ONWORD_SIGNING_DIR:-../onword-backups/signing}"
RELEASE_IDENTITY="-"
if [[ -f "$SIGNING_DIR/onword-signing.keychain-db" && -f "$SIGNING_DIR/keychain-password.txt" ]]; then
  KEYCHAIN="$(cd "$SIGNING_DIR" && pwd)/onword-signing.keychain-db"
  security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password.txt")" "$KEYCHAIN"
  # codesign only finds identities in keychains on the search list.
  if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
  fi
  RELEASE_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/"Onword Release"/ {print $2; exit}')"
fi
if [[ -z "$RELEASE_IDENTITY" || "$RELEASE_IDENTITY" == "-" ]]; then
  RELEASE_IDENTITY="-"
  echo "warning: Onword Release certificate not found; signing ad-hoc (permissions reset after this update)" >&2
fi
OUT_DIR=dist/build SIGN_IDENTITY="$RELEASE_IDENTITY" SKIP_GOOGLE_OAUTH=$([[ "${INCLUDE_GOOGLE_OAUTH:-1}" == "1" ]] && echo 0 || echo 1) \
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
