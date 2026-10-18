# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Argus is a macOS 15+ menubar app (Swift 6, SwiftPM, no package dependencies, Apple silicon) that keeps a vault of logins for Claude Code, Codex and Antigravity CLI (agy). It switches each tool's live login in place and polls every saved account's 5-hour and 7-day allowance. The app was renamed from magpie-lite, which is why the repo folder, `magpie-lite-PRD.md` and `docs/design/magpie-lite/` still use the old name.

## Commands

| Command | What it does |
| --- | --- |
| `make build` | app bundle in `build/Argus.app`, ad-hoc signed, version stamped from `VERSION` |
| `make dev` | build, quit the running Argus, open the fresh build (the single-instance lock would otherwise keep the old one) |
| `make test` | `swift test` |
| `make check` | version check + `make guard` (the sandbox rules below, as greps) + build + test: what CI runs (`.github/workflows/ci.yml`, `macos-26`) |
| `make install` / `make run` | copy to `~/Applications` (Launch at login needs it there) / and open it |

Run one suite or test with `swift test --filter RowModelTests` or `swift test --filter "keeps its order"`. Tests use Swift Testing with raw-identifier names, and `--filter` matches any fragment of the name.

## Architecture

There are two targets. `ArgusCore` holds every piece of logic and the view models, and is what the tests exercise. `Argus` is the AppKit/SwiftUI shell, and `AppDelegate` is the only place the live environment is built. It creates `ToolEnvironment(home:codexHome:user:keychain: .login, security: SecurityCLI())` and wires `Vault`, `Poller`, `Switcher` and `AccountCommands` together.

Data flows one way:
1. The tool adapters (`Tools/ClaudeTool`, `CodexTool`, `AgyTool`) read the live login into a `LiveLogin` with an `Identity`.
2. `AppState` (`@MainActor @Observable`) holds the live logins, vault entries and per-account status.
3. `state.snapshot(tool)` returns a `ToolSnapshot`.
4. Pure view models turn the snapshot into what the views draw: `ToolCard`/`AccountRow` in `RowModel.swift`, plus `ManagerModel` and `MenuBarSummary`.
5. `PopoverView`, `ManagerView` and `StatusItemController` draw the result.

Put UI logic in the view models and test it there; the views are thin. The views follow the HTML mockups in `docs/design/magpie-lite/ui/`.

Key mechanisms, each spread across several files:
- **Per-tool exclusive section** (ADR-0003): `Vault.exclusive(_:_:)` chains one task per tool. Save, Remove, Undo, a switch, a renewal and the poll-time sync-back all run inside it, so two operations on the same tool never interleave across their awaits.
- **Keychain access goes only through `/usr/bin/security`** (`SecurityCLI` and `Keychain` in `Security.swift`), the same way the tools read their own items. `security -w` prints hex when a value has non-printable bytes, and `decoded(_:)` converts it back. Error reasons name statuses, never item contents.
- **Vault** (ADR-0001): saved logins live at `~/Library/Application Support/Argus/vault/<tool>/<id>.json`, one owner-only file per account. Each file stores the exact live bytes plus an identity snapshot. Writes are atomic, and the previous version is kept as `.prev`. A refresh token that another entry already holds is refused (a `VaultError` with `sharedWith` set).
- **Switch** (`Switcher` in `Switch.swift`): the outgoing live login is saved back first. Then the target is written into every live store, the result is verified, and every store is restored on failure.
  - Claude: the `Claude Code-credentials` Keychain item plus `oauthAccount` in `~/.claude.json`, taken under Claude Code's own lock directories (`ClaudeLocks`). A switch cut short is rolled forward at launch from the digest journal `vault/claude-switch.json` (`settleInterruptedSwitch`).
  - Codex: `auth.json` in `CODEX_HOME`, written through symlinks. A running Codex app-server daemon is then restarted (`CodexDaemon`). Codex logins stored in the Keychain are shown but never switched.
  - agy: its Keychain item and its token file.
- **Polling and renewal**: `Poller` fetches a batch every 3, 5 or 10 minutes.
  - Requests go out one at a time per vendor, a 429 puts that account into backoff, and minimum gaps persist across restarts in `readings.json`.
  - Opening the popover reads and sends nothing. Live logins are read by interval batches and the refresh buttons, and `rereadLive()` (local stores only, no network) runs after a switch.
  - `Renewer` (ADR-0002) renews only saved accounts that aren't live; each tool keeps renewing its own live login.
  - The OAuth client IDs live in `OAuthClients.swift` and `Renewal.swift`.

## Rules that aren't obvious from the code

- `make guard` enforces the first two rules. `Sources/ArgusCore` and `Tests` never reach the owner's real environment: no home folder, environment variables, `UserDefaults.standard`, `URLSession.shared`, `NSUserName` or `applicationSupportDirectory`. Only `Sources/Argus` builds the live environment. Tests run inside `TestSandbox` (temp folders plus a disposable keychain file).
- Tests may run the real `security` tool only through `TestGuardedSecurity` in `Tests/ArgusCoreTests/Support/`. If you give `security add-generic-password` a keychain path that doesn't exist, it writes to the **login keychain** instead. Other tests script `security` with `ScriptedSecurity`.
- Never print credential values while debugging. Report exit codes, key names and sizes instead. To exercise a switch, use the tests or fixtures, never the owner's live logins.
- Leave wall-clock assertions room for a loaded CI runner (current bounds are 5 s). The shared runner once took 1.28 s for a 0.2 s timeout.
- A test name starting `REQ/F0x-AC-x.cN` covers that acceptance criterion in `docs/design/magpie-lite/`.

## Docs and change records

- `docs/design/magpie-lite/tech-design.md` is the design source of truth: architecture, the FR/AC rows under `## Behaviors`, and a dated `## Changelog`. `features.md` repeats the AC rows. When behaviour changes, update the row in both files and add a changelog line. Decisions are in `docs/adr/`.
- `CHANGELOG.md` follows Keep a Changelog. Every user-visible change goes under `[Unreleased]` in the same commit.

## Versioning and release

- `VERSION` holds the Semantic Version. `make build` stamps it into the bundle's `CFBundleShortVersionString`, and `CFBundleVersion` is `git rev-list --count HEAD`. `Resources/Info.plist` has no version keys.
- To release: `make bump VERSION=x.y.z` (writes `VERSION` and rolls `[Unreleased]` into `[x.y.z] - <date>`), then commit, then `make release`. The release builds an arm64 bundle signed with the Developer ID and hardened runtime, notarizes and staples it, builds a DMG, and tags `vX.Y.Z`. After that, push and run `make publish`, which pushes the tag and creates the GitHub release with the changelog section as notes.
- `make release` runs on the signing Mac only, never in CI. It needs the Developer ID identity in the login keychain and the notarytool profile `notary`, and it refuses a dirty tree. Its build step reads the working tree, so don't edit sources while a release build is running.
- `scripts/*.sh` run under `set -euo pipefail`. Don't pipe into `grep -q`: its early exit kills the writer with SIGPIPE and fails the pipeline even on a match. Use `grep … >/dev/null` instead.
