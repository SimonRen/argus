#!/usr/bin/env bash
set -euo pipefail

# Argus — start a release: set VERSION to x.y.z and roll CHANGELOG.md's [Unreleased] section into "[x.y.z] - <today>",
# leaving a fresh, empty [Unreleased] above it. Commit the result, then `make release VERSION=x.y.z`.
#
# Usage: scripts/bump.sh x.y.z   (via `make bump VERSION=x.y.z`)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

NEW="${1:-}"
[[ "$NEW" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "usage: make bump VERSION=x.y.z (Semantic Versioning, e.g. 0.2.0)"
grep -qF "## [$NEW]" CHANGELOG.md && fail "CHANGELOG.md already has a [$NEW] section."
grep -q '^## \[Unreleased\]$' CHANGELOG.md || fail "CHANGELOG.md has no '## [Unreleased]' heading."

# The Unreleased section must say what the release brings.
BODY="$(awk '/^## \[Unreleased\]$/ { on = 1; next } /^## \[/ { on = 0 } on && NF' CHANGELOG.md)"
[[ -n "$BODY" ]] || fail "CHANGELOG.md's [Unreleased] section is empty; list the changes first."

TODAY="$(date '+%Y-%m-%d')"
awk -v version="$NEW" -v today="$TODAY" '
  /^## \[Unreleased\]$/ && !done { print; print ""; print "## [" version "] - " today; done = 1; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
printf '%s\n' "$NEW" > VERSION

echo "→ VERSION $NEW; CHANGELOG.md has [$NEW] - $TODAY. Commit both, then: make release VERSION=$NEW"
