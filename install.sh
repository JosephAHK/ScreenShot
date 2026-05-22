#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ScreenShot"
SYSTEM_DEST="/Applications/$APP_NAME.app"
USER_DEST="$HOME/Applications/$APP_NAME.app"

"$ROOT/build.sh"

osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
killall "$APP_NAME" 2>/dev/null || true
sleep 1

tccutil reset ScreenCapture com.screenshot.app 2>/dev/null || true

install_to() {
  local dest="$1"
  echo "Installing to $dest ..."
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  ditto "$ROOT/build/$APP_NAME.app" "$dest" || return 1
  xattr -cr "$dest" 2>/dev/null || true
  echo "Installed: $dest"
  open "$dest"
}

if install_to "$SYSTEM_DEST"; then
  if [[ -d "$USER_DEST" ]]; then
    echo "Removing stale duplicate at $USER_DEST"
    rm -rf "$USER_DEST"
  fi
elif install_to "$USER_DEST"; then
  if [[ -d "$SYSTEM_DEST" ]]; then
    echo "Removing stale duplicate at $SYSTEM_DEST (may need sudo)"
    rm -rf "$SYSTEM_DEST" 2>/dev/null || sudo rm -rf "$SYSTEM_DEST" || true
  fi
  echo "(Installed in ~/Applications.)"
else
  echo "Could not write to /Applications or ~/Applications."
  echo "Run: sudo ditto \"$ROOT/build/$APP_NAME.app\" \"$SYSTEM_DEST\""
  exit 1
fi

echo ""
echo "Press F4 anywhere to start a region capture."
echo "First use will prompt for Screen Recording permission."
