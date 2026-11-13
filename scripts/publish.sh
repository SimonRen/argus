#!/usr/bin/env bash
set -euo pipefail

# Argus — publish a released DMG as the GitHub release v<version>, with its SHA-256 beside it and the version's
# CHANGELOG.md section as the notes. A HUMAN runs this: it pushes the tag `make release` made and creates the release on
# GitHub. Needs the `gh` CLI, logged in, and the Sparkle update key in the login keychain (account `argus`).
#
# The release also carries appcast.xml, the feed every installed Argus reads from
# https://github.com/SimonRen/argus/releases/latest/download/appcast.xml: one item for this version, its DMG signed with
# the update key, the same notes as Markdown.
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

# The feed: the build number is the tag's commit count, as `make release` stamped it into the bundle.
BUILD="$(git rev-list --count "$TAG")"
grep -F ']]>' "$NOTES" >/dev/null && fail "the [$VERSION] notes contain ']]>', which would end the appcast's CDATA early."
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account argus -p "$DMG")" || fail "sign_update could not sign $DMG with the \`argus\` key."
FEED_DIR="$(mktemp -d)"
trap 'rm -f "$NOTES"; rm -rf "$FEED_DIR"' EXIT
APPCAST="$FEED_DIR/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Argus</title>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>$(date -R)</pubDate>
      <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
      <enclosure url="https://github.com/SimonRen/argus/releases/download/$TAG/$(basename "$DMG")"
                 sparkle:edSignature="$SIGNATURE" length="$(stat -f%z "$DMG")" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST" || fail "the generated appcast is not well-formed XML."

git remote get-url origin >/dev/null 2>&1 || fail "no 'origin' remote; add the GitHub repository and push first."
git fetch --quiet origin
# The tag goes on a commit GitHub already has.
[[ -n "$(git branch -r --contains "$COMMIT")" ]] || fail "$TAG's commit ($(git rev-parse --short "$COMMIT")) is not pushed; push it first."
gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists."

git push origin "refs/tags/$TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" "$APPCAST" --verify-tag --title "Argus $TAG" --notes-file "$NOTES"
echo "→ published $TAG"
