# Changelog

All notable changes to Argus are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version lives in [`VERSION`](VERSION);
`make bump VERSION=x.y.z` rolls the Unreleased section below into that release.

## [Unreleased]

### Added

- The popover shows Argus's version after its name.

## [0.6.0] - 2026-10-22

### Added

- A 5h switch beside Show in menubar on each provider's page in the manager. When it's on, the menubar shows that provider's 5-hour use above its 7-day use. It's off by default.

### Changed

- The manager window can't be made narrower than 1000 pt, so each provider's header keeps room for its name beside the new switch.

## [0.5.4] - 2026-10-21

### Fixed

- Argus no longer slows down the longer it runs. Each time the popover opened and closed, the menubar started redrawing a few more times on every update, so after a while each poll kept the app busy for seconds: the pointer spun and buttons were slow to respond. It now redraws once per update, and each redraw is cheaper.

## [0.5.3] - 2026-10-20

### Fixed

- Save, Switch, Remove and Undo now show that they're working. The button you pressed reads "Saving…", "Switching…" or "Removing…" (in the popover the switch arrow spins), and that context's other account buttons wait until it's done. Adding or removing a context in the manager waits the same way.
- A switch then shows how it went on its row for 2 seconds, "Switched" or "Not switched", and that context's buttons stay locked meanwhile, so a quick second click can't start another switch, even after a failed one.
- A switch's result shows as soon as the switch is done. It no longer waits for the other tools' logins to be read again, which could take seconds while one of them was renewing.
- The Launch at login toggle moves at once and no longer holds up the app while macOS registers it.
- Saving the latest readings after each refresh no longer waits for the disk.

## [0.5.2] - 2026-10-19

### Fixed

- A context's name in the menubar is drawn in the full text color, so it stays readable on any wallpaper.

## [0.5.1] - 2026-10-19

### Changed

- Context names on the popover cards, in the manager and in the menubar are shown in capitals.
- Reset times read "2h 14m" instead of "in 2h 14m".

## [0.5.0] - 2026-10-19

### Changed

- Each Claude Code and Codex context now keeps its own saved accounts. Save, Switch and Remove act on that context only, so removing an account from one context leaves the others alone. Your existing saved accounts belong to the default context; save another context's logins from its own page. An account saved in several contexts is still checked once and shows the same usage everywhere.
- The same account can now be live in several contexts at once, each on its own sign-in. A switch is refused only when it would copy one context's login into another.
- Removing a context keeps its saved accounts on disk, unused, and adding the same folder again brings them back.
- Polling no longer runs like clockwork. Each wait between refreshes varies by up to 10% either way, and requests to one service go 3 to 10 seconds apart at random instead of every 2 seconds.

## [0.4.0] - 2026-10-19

### Changed

- Each Claude Code and Codex context is now its own section: a card in the popover and a page in the manager's sidebar, named after the context. A section lists its live login and the saved accounts not live in another context, and Save and Switch act on that context. The context picker is gone.
- Show in menubar and Show in popover are set per context, and an added context's menubar value carries its name.

## [0.3.0] - 2026-10-19

### Added

- Contexts for Claude Code and Codex. Add other `CLAUDE_CONFIG_DIR` or `CODEX_HOME` folders under Contexts in the manager, then pick one from the tool's card in the popover or from the manager header. Argus shows, saves and switches the selected folder's login; saved accounts are shared by every folder, and each row says whether its exact path holds a login.
- A switch is refused while that account is live in another context of the same tool, since one login copied into two folders signs one of them out at its next renewal. Signing in with the tool itself in each folder keeps both.

- The Contexts list flags two folders sharing one login (a copied Codex folder), whichever renews first signs the other out, and a folder whose account can't be read, which pauses renewing that tool's saved accounts.

### Changed

- After a Codex switch, only the app-server daemon of that Codex home is restarted, and the desktop-app note appears only for the default home.
- An account live in several contexts is polled with the login whose token lasts longest, and switch notices name the context ("Claude Code (Work) now signs in as …").
- A switch is paused while another context's login can't be read, and a context is kept while its folder runs on the saved login that only it has live, since Argus would otherwise renew that login and sign the folder out.
- A Codex folder signed in with an API key no longer holds up renewal of saved Codex accounts.

### Fixed

- The Claude Keychain account follows Claude Code's own rule: a login name with anything other than letters, digits, `.`, `_` or `-` reads the `claude-code-user` account.
- Claude Code's legacy lock is taken at the config folder's real path, so a symlinked `~/.claude` locks the same directory Claude Code does.

## [0.2.4] - 2026-10-18

### Changed

- Argus now runs on macOS 15 Sequoia or later on Apple silicon; it required macOS 26 before.

## [0.2.3] - 2026-10-18

### Fixed

- The first menubar popover open no longer waits for SwiftUI and AppKit to build its hosting window; that work is warmed after launch.

## [0.2.2] - 2026-10-18

### Fixed

- Manager table columns now follow the current detail width after a resize or zoom restore, keeping the sidebar and account column visible.

## [0.2.1] - 2026-10-17

### Changed

- Popover rows no longer show how long ago an account was last fetched; the manager still does.

### Fixed

- Antigravity's Gemini 4 Argon weekly limit shows, as its own "Argon 7d" column, and Antigravity's columns read 5h and
  7d like Claude Code's instead of "Gemini 5h" and "Gemini 7d".

## [0.2.0] - 2026-10-17

### Changed

- The manager's header no longer shows the saved-account count: it reads "Signed in as <email>" (with " — not saved"
  when the live login isn't saved) or "Not signed in".
- The popover shows each tool as a table: the window names (5h, 7d, and model limits such as Fable 7d) once at the top,
  and per account a bar for each with the share used on it and the reset time under it. A window an account doesn't have
  reads "none" instead of "weekly only", in the manager too; an account that needs sign-in or hasn't been fetched yet
  shows one box across the columns.
- Popover rows show the email up to the @ (the full email on hover) with the plan and "live" under it; Switch is an icon
  button, and "Show less" reads "Live only".
- Opening the popover no longer re-reads the live logins; they refresh on the interval, with the refresh buttons and after
  a switch.
- The menubar's tool icons are drawn at the same size as the other menubar icons.

## [0.1.1] - 2026-10-17

### Added

- MIT license.

### Changed

- Account lists keep their order when you switch: the expanded popover card and the manager list every account by email,
  and only the Live mark moves.
- New app icon: a flat amber hourglass on ink indigo inside an open allowance ring.

## [0.1.0] - 2026-10-17

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
