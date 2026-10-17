# Changelog

All notable changes to Argus are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version lives in [`VERSION`](VERSION);
`make bump VERSION=x.y.z` rolls the Unreleased section below into that release.

## [Unreleased]

### Added

- Menubar item: each tool's live account with its 7-day use, in the menu bar's own font; values over 85 % in red.
- Popover: a card per tool with the live and saved accounts, 5-hour and 7-day bars with reset times, stale and
  needs-sign-in states, Switch, per-account and live refresh, and a Save banner for an unsaved live login.
- Manager window: saved accounts per tool, Save current login, Switch, two-click Remove with Undo, refresh interval
  (3 / 5 / 10 min), Show in menubar / popover per tool, and Launch at login.
- Login vault: one owner-only file per saved account in Application Support, excluded from Time Machine.
- In-place switching for Claude Code (Keychain item and `oauthAccount`, under Claude Code's locks), Codex (`auth.json`,
  with an automatic restart of a running Codex app-server) and Antigravity CLI (Keychain item and token file). The
  outgoing login is saved back first; a failed switch restores every live store; a switch cut short is finished at the
  next launch.
- Background allowance polling for every saved account, with token renewal for saved accounts, one request at a time
  per vendor, per-account 429 backoff, and minimum gaps that hold across restarts.
- Signed and notarized release builds (`make release`) and GitHub releases with checksums (`make publish`).
