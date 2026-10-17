# Argus

**Every login and every allowance, at a glance.** A macOS menubar app that keeps the logins of
**Claude Code**, **Codex** and **Antigravity CLI** (agy), switches between them in place, and watches
each account's 5-hour and 7-day allowance in the background.

Named after Argus Panoptes, the hundred-eyed watchman of Greek myth.

| | |
| --- | --- |
| Platform | macOS 26, Apple silicon; menubar accessory (`LSUIElement`) |
| Tools | Claude Code, Codex CLI, Antigravity CLI |
| Source | Swift 6, SwiftUI + AppKit, no package dependencies |
| Spec | [`docs/design/magpie-lite/`](docs/design/magpie-lite/) · decisions in [`docs/adr/`](docs/adr/) |

## Features

- **Menubar** — each tool's live account and its 7-day use, in the menu bar's own font; a value over 85 % turns red.
- **Popover** — one card per tool: the live account and the saved ones, 5-hour and 7-day bars with reset times,
  stale and needs-sign-in states, Switch, and per-account refresh.
- **Manager window** — every saved account per tool, Save current login, Switch, Remove (two clicks, with Undo),
  the refresh interval (3 / 5 / 10 min), Show in menubar / popover, Launch at login.
- **Switching in place** — the tool's own live login is replaced, so new sessions use the new account:
  - Claude Code: the Keychain item and the config's `oauthAccount`, under Claude Code's own lock directories;
    running sessions follow within about 30 s.
  - Codex: `auth.json`; a running Codex app-server is restarted so attached sessions move over.
  - Antigravity CLI: its Keychain item and token file, from its next session.
  The outgoing login is saved back first, and a failed switch puts every live store back.
- **Background allowance polling** — saved accounts' tokens are renewed by the app; requests go one at a time per
  vendor, with per-account backoff after a 429 and minimum gaps that hold across restarts.

## Install

Download `Argus-v<version>.dmg` from [Releases](../../releases), open it and drag **Argus** to Applications.
The app is signed with a Developer ID and notarized by Apple, so it opens without a Gatekeeper warning.
Check the download against the `.sha256` file published beside it:

```sh
shasum -a 256 -c Argus-v<version>.dmg.sha256
```

Or build from source (below) and run `make install`.

## Use

1. Sign in with each tool as usual (`claude`, `codex`, `agy`).
2. Open Argus from the menu bar and choose **Save login** on the banner, or **Save current login** in the manager.
3. To add another account, sign in to it with the tool — without signing out first — and save again.
4. **Switch** any saved account to make it the tool's live login.

## Privacy and security

- Saved logins live in `~/Library/Application Support/Argus/vault/<tool>/<id>.json`: one file per account,
  mode `0600` in `0700` folders, excluded from Time Machine. They are not encrypted at rest — the same user can
  already read every tool's own login.
- Credentials are only ever sent to each vendor's own endpoints, for the allowance and token-renewal requests the
  tools themselves make.
- Keychain items are read and written through `/usr/bin/security`, the way the tools read them; values longer than
  4032 bytes are passed on the command line, briefly visible to the same user's processes.
- A switch cut short (the app killed between two writes) is finished at the next launch, so a tool's Keychain login
  and its account record never disagree.

## Known limits

- `CLAUDE_CONFIG_DIR` setups are not switched (Claude Code then uses a different Keychain item).
- Codex logins kept in the Keychain (`keyring` / `auto` store modes) are shown but not switched.
- The Codex desktop app keeps the previous account until it is restarted.

## Build and test

Prerequisites: macOS 26 and Xcode 26 (Swift 6.2 or later).

| Command | What it does |
| --- | --- |
| `make build` | app bundle in `build/Argus.app`, ad-hoc signed |
| `make dev` | build, quit a running Argus, open the fresh build |
| `make test` | the whole test suite (`swift test`) |
| `make check` | version check + sandbox guards + build + test — what CI runs |
| `make install` / `make run` | copy to `~/Applications` (Launch at login needs it there) / and open it |
| `make clean` | delete build products |

Tests never touch the real `~/.claude*`, `~/.codex`, `~/.gemini`, the login keychain or Application Support:
every test runs in a temp folder with a disposable keychain.

### Layout

```
Sources/ArgusCore/   the engine: live logins, vault, switch, renewal, allowance polling, view models
Sources/Argus/       the app: menubar item, popover, manager window
Tests/ArgusCoreTests/
Resources/           Info.plist, app icon, tool icons
scripts/             release, DMG and publish scripts
docs/                design pack and ADRs
```

## Versioning

- [`VERSION`](VERSION) holds the version, `MAJOR.MINOR.PATCH` per [Semantic Versioning](https://semver.org): while it is
  `0.y.z`, a MINOR bump may change behaviour; from `1.0.0`, MAJOR is for changes that break saved logins or settings.
- The build stamps it into the app's `CFBundleShortVersionString`; `CFBundleVersion` is the commit count, so every
  build of a later commit has a higher build number.
- [`CHANGELOG.md`](CHANGELOG.md) follows [Keep a Changelog](https://keepachangelog.com): every user-visible change goes
  under `[Unreleased]` in the same commit, and the release's section becomes its GitHub release notes.
- Each release is tagged `vX.Y.Z` on the commit it was built from.

## Release

Releases are built, signed and notarized on the signing Mac, never in CI.

One-time setup:

- a **Developer ID Application** certificate in the login keychain
  (override the default with `APPLE_SIGNING_IDENTITY`);
- a notarytool keychain profile named `notary` (override with `NOTARY_PROFILE`), from an App Store Connect API key:

  ```sh
  xcrun notarytool store-credentials notary --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
  ```

Each release:

```sh
make bump VERSION=0.2.0       # VERSION → 0.2.0; CHANGELOG [Unreleased] → [0.2.0] - <today>; commit both
make release VERSION=0.2.0    # test → arm64 build → Developer ID + hardened runtime → notarize + staple
                              # → signed, notarized, stapled releases/Argus-v0.2.0.dmg (+ .sha256), tag v0.2.0
git push                      # the tag goes on a pushed commit
make publish VERSION=0.2.0    # push tag v0.2.0; GitHub release with the DMG, its checksum and the changelog notes
```

`make bump` refuses a version that isn't `x.y.z`, one CHANGELOG.md already has, or an empty `[Unreleased]`.
`make release` refuses a dirty tree, a version other than `VERSION`, a version with no CHANGELOG.md section, an
existing tag, or a missing signing identity, before it builds anything.

## Credits

Tool icons are from [CodexBar](https://github.com/steipete/CodexBar) (MIT); see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE) © 2026 Simon Ren
