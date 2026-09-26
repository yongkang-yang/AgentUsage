#!/bin/bash
# Builds AgentUsage.app. SwiftPM alone produces a bare executable; a menu bar app
# needs a bundle so it gets an Info.plist (LSUIElement) and a stable identity
# for its privacy grants.
set -euo pipefail

NAME="AgentUsage"
BUNDLE_ID="nl.yongkang.agentusage"
CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/$NAME.app"

INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    *) echo "usage: $0 [--no-install]" >&2; exit 2 ;;
  esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
for resource in "$ROOT"/Resources/*; do
  case "$resource" in *Info.plist) ;; *) cp -R "$resource" "$APP/Contents/Resources/" ;; esac
done

# A real signing identity keeps the keychain items across rebuilds; an ad-hoc signature changes every
# build and macOS treats each one as a new app. Identities are matched by
# SHA-1 hash because two certificates with the same common name make codesign
# refuse an ambiguous match. Override with CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | awk '/Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | awk '/Apple Development/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "warning: no signing identity found; ad-hoc signing. Permissions will reset on every build." >&2
fi

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Signature|TeamIdentifier)" || true

echo "Built $APP"

# By default the build is installed over /Applications/$NAME.app, the copy that
# is actually launched: a bundle left only in the repo means the running app
# silently stays older than every fix. --no-install skips it.
if [ "$INSTALL" = 0 ]; then
  exit 0
fi

INSTALL_DIR="/Applications/$NAME.app"
echo "==> Installing to $INSTALL_DIR"

# Quit a running copy and wait for it to exit before replacing its bundle,
# then relaunch only if something was running before.
WAS_RUNNING=0
if pgrep -xq "$NAME"; then
  WAS_RUNNING=1
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  for _ in $(seq 50); do
    pgrep -xq "$NAME" || break
    sleep 0.1
  done
  if pgrep -xq "$NAME"; then
    echo "$NAME did not quit; not installing" >&2
    exit 1
  fi
fi

rm -rf "$INSTALL_DIR"
ditto "$APP" "$INSTALL_DIR"
echo "    installed $INSTALL_DIR"

if [ "$WAS_RUNNING" = 1 ]; then
  open "$INSTALL_DIR"
  echo "    relaunched"
else
  echo "  run:  open $INSTALL_DIR"
fi
