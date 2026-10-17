#!/usr/bin/env bash
set -euo pipefail

# Argus — distribution release: Apple-silicon Release build → Developer ID signature with the hardened runtime and a
# secure timestamp → notarize → staple → DMG → sign, notarize and staple the DMG → releases/Argus-v<version>.dmg.
# A HUMAN runs this on the signing Mac (keychain unlock / Touch ID); signing credentials never leave it, and nothing here
# is for CI.
#
# The chain that lets the app open without Gatekeeper's "unidentified developer" warning, offline too:
#   1. codesign with a "Developer ID Application" certificate and the hardened runtime
#   2. notarize: Apple scans the upload and issues a ticket (notarytool --wait)
#   3. staple: the ticket is attached to the .app and the .dmg, so no online check is needed
#
# Prerequisites on the signing Mac:
#   - a "Developer ID Application" identity in the login keychain (default below; override with APPLE_SIGNING_IDENTITY)
#   - a notarytool keychain profile (default `notary`; override with NOTARY_PROFILE), created once from an
#     App Store Connect API key (App Store Connect → Users and Access → Integrations; the .p8 downloads only once):
#       xcrun notarytool store-credentials notary \
#         --key <path/to/AuthKey_XXXXXXXXXX.p8> --key-id XXXXXXXXXX --issuer <issuer-uuid>
#     (--issuer is required for a Team key and must be left out for an Individual key). The Apple ID form also works:
#       xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#   - Xcode command line tools (swift, codesign, notarytool, stapler, hdiutil)
#
# Usage: scripts/release.sh [x.y.z]   (via `make release VERSION=x.y.z`; the version must match VERSION, and
#        CHANGELOG.md must have its section — `make bump VERSION=x.y.z` does both). A success tags the commit v<x.y.z>.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN_ID="${APPLE_SIGNING_IDENTITY:-Developer ID Application: JUNKUN REN (DN4YAHWP2P)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
OUT="build_release"
APP="$OUT/Argus.app"
RELEASES="$ROOT/releases"

fail() { echo "FAIL: $*" >&2; exit 1; }

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD)"
TAG="v$VERSION"
# Fail fast, before the build and two notarization round-trips.
if [[ -n "${1:-}" && "$1" != "$VERSION" ]]; then
  fail "requested v$1 but VERSION says $VERSION — run \`make bump VERSION=$1\` and commit it first."
fi
grep -qF "## [$VERSION] - " CHANGELOG.md || fail "CHANGELOG.md has no [$VERSION] section — run \`make bump VERSION=$VERSION\` and commit it first."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG is already tagged; a new release needs a new version."
# A release is rebuilt from a commit, never from uncommitted bytes.
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes; commit or stash them first."
security find-identity -v -p codesigning | grep -qF "\"$SIGN_ID\"" || fail "signing identity \"$SIGN_ID\" is not in the keychain."

DMG="$RELEASES/Argus-v${VERSION}.dmg"
echo "=== Argus v$VERSION (build $BUILD) — signed, notarized DMG ==="
echo "    identity : $SIGN_ID"
echo "    profile  : $NOTARY_PROFILE"
echo "    commit   : $(git rev-parse --short HEAD)"

# 1. The gate, then the Apple-silicon Release build signed with the Developer ID, hardened runtime and timestamp.
echo "→ Testing…"
make test
echo "→ Building and signing Argus.app (arm64, hardened runtime)…"
rm -rf "$OUT"
make build OUT="$OUT" SIGN="$SIGN_ID" CODESIGN_FLAGS="--options runtime --timestamp" SWIFT_FLAGS="--arch arm64"

# 2. Verify the slice and the signature before spending a notarization round-trip.
echo "→ Verifying…"
[[ "$(lipo -archs "$APP/Contents/MacOS/Argus")" == "arm64" ]] || fail "the binary is not arm64 only: $(lipo -archs "$APP/Contents/MacOS/Argus")"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Identifier|Runtime Version)=|flags=" || true
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" || fail "the hardened runtime is not on."
STAMPED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$STAMPED" == "$VERSION" ]] || fail "the bundle says $STAMPED, not $VERSION."
# Notarization rejects a binary carrying get-task-allow.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  fail "the binary carries com.apple.security.get-task-allow; notarization would reject it."
fi

# 3. Notarize the app and staple it, so the copy dragged out of the DMG clears Gatekeeper offline.
echo "→ Notarizing the app…"
mkdir -p "$RELEASES"
ZIP="$RELEASES/Argus-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"

# 4. The DMG from the stapled app, signed with the same identity.
echo "→ Building the DMG…"
scripts/make-dmg.sh "$APP" "$DMG"
codesign --sign "$SIGN_ID" --timestamp "$DMG"

# 5. Notarize and staple the DMG itself.
echo "→ Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# 6. Gatekeeper must accept both, and the checksum goes beside the DMG.
echo "→ Gatekeeper assessment:"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
(cd "$RELEASES" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
git tag -a "$TAG" -m "Argus $TAG"

echo ""
echo "=== Release complete: Argus v$VERSION (build $BUILD) ==="
ls -lh "$DMG" "$DMG.sha256"
echo ""
echo "Tagged $TAG at $(git rev-parse --short HEAD)."
echo "Next: push the commit, then \`make publish VERSION=$VERSION\` to push the tag and create the GitHub release."
