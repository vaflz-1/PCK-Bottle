#!/usr/bin/env bash
set -euo pipefail

# Build a distributable .dmg containing "PCK Bottle.app" plus a drag-to-install
# /Applications symlink. Uses only hdiutil (no Homebrew dependency).
#
# Usage:
#   bash macos/PCKBottle/scripts/make-dmg.sh [path/to/PCK Bottle.app] [out.dmg]
#
# If the .app path is omitted it defaults to the build output of build-app.sh.
# The version (for the default dmg name and volume name) comes from VERSION.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"

APP_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || true)}"
APP_VERSION="${APP_VERSION:-1.0.0}"

APP_PATH="${1:-$PACKAGE_DIR/build/PCK Bottle.app}"
DMG_PATH="${2:-$PACKAGE_DIR/build/PCK Bottle $APP_VERSION.dmg}"
VOL_NAME="PCK Bottle"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  echo "Build it first:  CONFIGURATION=release bash $SCRIPT_DIR/build-app.sh" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
