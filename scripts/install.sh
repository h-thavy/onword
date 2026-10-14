#!/usr/bin/env bash
# Onword installer.
#
#   curl -fsSL https://raw.githubusercontent.com/h-thavy/onword/main/scripts/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --uninstall          # remove the app, keep your data
#   curl -fsSL .../install.sh | bash -s -- --uninstall --purge  # also delete history, notes, meetings, models
#
# Environment: ONWORD_INSTALL_DIR (default /Applications, or ~/Applications if not writable),
#              ONWORD_NO_OPEN=1 (don't launch after installing), ONWORD_VERSION=v0.1.0 (pin a release).
set -euo pipefail

REPO="h-thavy/onword"
BUNDLE_ID="io.github.h-thavy.onword"
APP_NAME="Onword.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

uninstall=0
purge=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall=1 ;;
    --purge) purge=1 ;;
    -h|--help) sed -n '2,10p' "$0" 2>/dev/null || true; exit 0 ;;
    *) fail "Unknown option: $arg" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "Onword is a macOS app."

quit_running() {
  if pgrep -x Onword >/dev/null 2>&1; then
    osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Onword >/dev/null 2>&1 || break; sleep 0.5; done
    pkill -x Onword 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- uninstall
if [[ $uninstall == 1 ]]; then
  bold "Uninstalling Onword"
  quit_running
  for dir in /Applications "$HOME/Applications"; do
    if [[ -d "$dir/$APP_NAME" ]]; then
      "$LSREGISTER" -u "$dir/$APP_NAME" >/dev/null 2>&1 || true
      rm -rf "${dir:?}/$APP_NAME" && info "Removed $dir/$APP_NAME"
    fi
  done
  if [[ $purge == 1 ]]; then
    rm -rf "$HOME/Library/Application Support/Onword" && info "Deleted ~/Library/Application Support/Onword"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
    info "Deleted settings and permission entries"
  else
    info "Your data is still in ~/Library/Application Support/Onword (use --purge to delete it)."
  fi
  bold "Done."
  exit 0
fi

# ---------------------------------------------------------------- checks
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]]; then
  fail "Onword needs a Mac with Apple Silicon (M1 or later)."
fi
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < 14 )); then
  fail "Onword needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion))."
fi

if [[ -n "${ONWORD_VERSION:-}" ]]; then
  base="https://github.com/$REPO/releases/download/$ONWORD_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

if [[ -n "${ONWORD_INSTALL_DIR:-}" ]]; then
  dest="$ONWORD_INSTALL_DIR"
elif [[ -w /Applications ]]; then
  dest="/Applications"
else
  dest="$HOME/Applications"
fi
mkdir -p "$dest"

# ---------------------------------------------------------------- download
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bold "Downloading Onword"
curl -fL --progress-bar "$base/Onword.zip" -o "$tmp/Onword.zip" || fail "Couldn't download $base/Onword.zip"
curl -fsSL "$base/Onword.zip.sha256" -o "$tmp/Onword.zip.sha256" || fail "Couldn't download the checksum."

expected="$(tr -d ' \n' < "$tmp/Onword.zip.sha256")"
actual="$(shasum -a 256 "$tmp/Onword.zip" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] || fail "Checksum mismatch (expected $expected, got $actual). Try again."
info "Checksum OK"

ditto -x -k "$tmp/Onword.zip" "$tmp/unpacked"
[[ -d "$tmp/unpacked/$APP_NAME" ]] || fail "The download didn't contain $APP_NAME."
codesign --verify --deep --strict "$tmp/unpacked/$APP_NAME" 2>/dev/null || fail "The app's code signature is damaged."

# ---------------------------------------------------------------- install
bold "Installing to $dest"
quit_running
updating=0
[[ -d "$dest/$APP_NAME" ]] && updating=1
rm -rf "${dest:?}/$APP_NAME"
ditto "$tmp/unpacked/$APP_NAME" "$dest/$APP_NAME"
# Downloaded with curl, so there should be no quarantine flag; clear it anyway so macOS doesn't block it.
xattr -dr com.apple.quarantine "$dest/$APP_NAME" 2>/dev/null || true
"$LSREGISTER" -f "$dest/$APP_NAME" >/dev/null 2>&1 || true

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo "?")"
bold "Onword $version installed."

if [[ $updating == 1 ]]; then
  echo
  info "Updated. If your shortcut stops working, macOS needs the permissions again:"
  info "System Settings → Privacy & Security → Accessibility and Input Monitoring:"
  info "remove Onword with –, then add it back with +."
fi

if [[ "${ONWORD_NO_OPEN:-0}" != "1" ]]; then
  open "$dest/$APP_NAME"
  echo
  info "Onword is in your menu bar. The setup window will guide you through the rest."
fi
