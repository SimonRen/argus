#!/usr/bin/env bash
set -euo pipefail

# Argus — publish a released DMG as the GitHub release v<version>, with its SHA-256 beside it and the version's
# CHANGELOG.md section as the notes. A HUMAN runs this: it pushes the tag `make release` made and creates the release on
# GitHub. Needs the `gh` CLI, logged in.
#
# Usage: scripts/publish.sh [x.y.z]   (via `make publish VERSION=x.y.z`; defaults to the VERSION file)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

VERSION="${1:-$(cat VERSION)}"
TAG="v$VERSION"
DMG="releases/Argus-v${VERSION}.dmg"

[[ -f "$DMG" && -f "$DMG.sha256" ]] || fail "$DMG (and its .sha256) not found; run \`make release VERSION=$VERSION\` first."
xcrun stapler validate "$DMG" >/dev/null || fail "$DMG has no stapled notarization ticket."
(cd releases && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null) || fail "$DMG does not match its checksum."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "no local tag $TAG; \`make release VERSION=$VERSION\` makes it."
COMMIT="$(git rev-list -n 1 "$TAG")"

# The notes are the version's section of CHANGELOG.md as it stood in the tagged commit.
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
git show "$TAG:CHANGELOG.md" | awk -v head="## [$VERSION]" '
  index($0, head) == 1 { on = 1; next }
  /^## \[/ { on = 0 }
  on
' > "$NOTES"
grep -q '[^[:space:]]' "$NOTES" || fail "CHANGELOG.md has no notes under [$VERSION] in $TAG."

git remote get-url origin >/dev/null 2>&1 || fail "no 'origin' remote; add the GitHub repository and push first."
git fetch --quiet origin
# The tag goes on a commit GitHub already has.
[[ -n "$(git branch -r --contains "$COMMIT")" ]] || fail "$TAG's commit ($(git rev-parse --short "$COMMIT")) is not pushed; push it first."
gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists."

git push origin "refs/tags/$TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" --verify-tag --title "Argus $TAG" --notes-file "$NOTES"
echo "→ published $TAG"
