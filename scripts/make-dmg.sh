#!/usr/bin/env bash
set -euo pipefail

# Build a drag-to-Applications DMG from a .app. It only packages; the caller signs and notarizes.
# Usage: make-dmg.sh <app-path> <dmg-out-path>
APP="${1:?usage: make-dmg.sh <app-path> <dmg-out>}"
OUT="${2:?usage: make-dmg.sh <app-path> <dmg-out>}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$OUT"
hdiutil create -volname "Argus" -srcfolder "$STAGING" -ov -format UDZO "$OUT"
echo "→ DMG: $OUT"
