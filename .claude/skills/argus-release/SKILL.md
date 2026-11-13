---
name: argus-release
description: Release and publish an Argus version — bump VERSION and CHANGELOG, signed + notarized DMG, GitHub release with the Sparkle appcast, then verify the live update feed. Use when asked to release, publish, ship or cut an Argus version, pick the next version number, or diagnose a failed release, notarization, publish or update check.
---

# Argus release & publish

One version ships in four steps, all from a clean `main` on the signing Mac:

| Step | Command | Who |
| --- | --- | --- |
| 1. Bump | `make bump VERSION=x.y.z`, commit `Release x.y.z`, push | agent, with approval |
| 2. Release | `make release VERSION=x.y.z` | the owner, or an agent the owner explicitly asked |
| 3. Publish | `make publish VERSION=x.y.z` | the owner, or an agent the owner explicitly asked |
| 4. Verify | the feed checks below | agent |

Commit and push stay approval-gated. Never start step 2 or 3 uninvited: they use the Developer ID, the notary
profile and the Sparkle update key, and they publish to every installed Argus.

## 0. Pre-flight

- On `main`, tree clean, `git status -sb` shows no ahead/behind, CI green on HEAD
  (`gh run list -R SimonRen/argus -L 1`).
- `CHANGELOG.md`'s `[Unreleased]` lists every user-visible change since the last tag
  (`git log --oneline $(git describe --tags --abbrev=0)..HEAD`). `make bump` refuses an empty section.
- **Pick the version by Semantic Versioning**: a new feature → minor (0.6.2 → 0.7.0), fixes only → patch, a
  breaking change to the vault or switch behaviour → say so and ask. Recommend one; don't default to patch.

## 1. Bump

`make bump VERSION=x.y.z` writes `VERSION` and rolls `[Unreleased]` into `[x.y.z] - <today>`. Run `make version-check`,
commit both files as `Release x.y.z` (no other files), push.

## 2. Release — `make release VERSION=x.y.z`

Takes 5–15 min (two notarization round-trips); run it in the background and log to a file
(`make release VERSION=x.y.z > /tmp/argus-release-x.y.z.log 2>&1`).

- It refuses: a version that isn't `VERSION`, a missing `[x.y.z]` changelog section, an existing tag, a dirty tree,
  a missing signing identity.
- It runs `make test`, builds arm64 with the hardened runtime and timestamp (Sparkle's `Autoupdate`, `Updater.app` and
  the framework are signed by `make build` before the app), verifies, and refuses a bundle whose `SUPublicEDKey`
  isn't the public half of the keychain's `argus` key.
- Output: `releases/Argus-vx.y.z.dmg` + `.sha256`, both app and DMG notarized and stapled, and a local tag `vx.y.z`.
- **Don't commit, edit sources or switch branches while it runs**: it builds from the working tree and tags HEAD
  at the end, so a commit made meanwhile gets the tag.
- Keychain prompts (codesign, notarytool): the owner clicks Always Allow. On `errSecInternalComponent`, the login
  keychain is locked: ask the owner to unlock it, then rerun; don't retry-loop.
- Notarization **Invalid** is a verdict, not a flake: `xcrun notarytool log <submission-id> --keychain-profile notary`
  and fix what it names. A failed run leaves no tag; rerun after the fix.

## 3. Publish — `make publish VERSION=x.y.z`

- It refuses a DMG without a staple or not matching its `.sha256`, a missing tag, notes that are empty or contain
  `]]>`, a tag commit not on `origin`, an existing release.
- It signs the DMG with `sign_update --account argus` (first use may raise a keychain prompt: Always Allow), writes
  a one-item `appcast.xml` (build number = `git rev-list --count vx.y.z`, notes = the changelog section as Markdown),
  pushes the tag, and creates the GitHub release with the DMG, `.sha256` and `appcast.xml`.
- If it dies after `git push` of the tag but before `gh release create`, rerun `make publish` — the push is a
  no-op and the release doesn't exist yet. If the release exists without `appcast.xml`, upload it by hand
  (`gh release upload vx.y.z <appcast.xml>`) rather than deleting the release.

## 4. Verify the live feed

Every installed Argus reads `https://github.com/SimonRen/argus/releases/latest/download/appcast.xml`. Check it serves
this version and that its signature verifies against the published DMG:

```bash
V=x.y.z; T=$(mktemp -d)
curl -fsSL https://github.com/SimonRen/argus/releases/latest/download/appcast.xml -o "$T/appcast.xml"
xmllint --noout "$T/appcast.xml"
xp() { xmllint --xpath "string($1)" "$T/appcast.xml"; }
[[ "$(xp '//*[local-name()="shortVersionString"]')" == "$V" ]] && echo "version ok"
[[ "$(xp '//*[local-name()="version"]')" == "$(git rev-list --count "v$V")" ]] && echo "build ok"
curl -fsSL "$(xp '//enclosure/@url')" -o "$T/Argus.dmg"
[[ "$(xp '//enclosure/@length')" == "$(stat -f%z "$T/Argus.dmg")" ]] && echo "length ok"
cmp -s "$T/Argus.dmg" "releases/Argus-v$V.dmg" && echo "same bytes as releases/"
.build/artifacts/sparkle/Sparkle/bin/sign_update --account argus --verify "$T/Argus.dmg" \
  "$(xp '//enclosure/@*[local-name()="edSignature"]')" && echo "signature ok"
rm -rf "$T"
```

All five lines must print. Then check the release page lists three assets (`gh release view vx.y.z`) and that CI
passed on the tag push.

## Facts that bite

- The update key's private half exists only in the signing Mac's login keychain (account `argus`). Lose it and no
  installed Argus accepts another update. Keep a backup: `generate_keys --account argus -x <file>`, stored offline.
  Never print it.
- `SUPublicEDKey` and `SUFeedURL` are in `Resources/Info.plist`. The feed URL is compiled into every install:
  changing it strands them.
- Sparkle orders updates by `CFBundleVersion`, the commit count on `main`. Releases from another branch, or after
  history rewrites, can get a lower count and never be offered.
- "latest" skips drafts and pre-releases: a release marked pre-release is invisible to the updater.
- The appcast lists only the newest version, so each release must carry its own `appcast.xml`; a release without it
  breaks updates for everyone until the next one.
- Installs of 0.6.2 or earlier have no updater; their owners install 0.7.0 or later by hand once.
- Testing an update locally: build an old and a new bundle with `make build OUT=… PLIST=<copy with SUFeedURL on
  127.0.0.1> BUILD_NUMBER=… APP_VERSION=… SIGN="Developer ID Application: …"`, DMG the new one with
  `scripts/make-dmg.sh`, sign it with `sign_update --account argus -p`, serve an appcast with
  `python3 -m http.server`. The test app shares the real bundle id: quit the owner's Argus first, and afterwards
  delete the `SU*` keys from `defaults read io.github.simonren.Argus` and relaunch `/Applications/Argus.app`.
