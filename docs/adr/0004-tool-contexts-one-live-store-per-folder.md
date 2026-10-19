# Tool contexts: one live store per config folder, saved accounts shared

> Superseded in part by ADR-0005: each context now keeps its own saved accounts, a switch is refused only for a copied login, and removing a context keeps its list unread instead of being guarded. The live-store rules below still hold.

Claude Code and Codex can each run from more than one folder: Claude Code from `CLAUDE_CONFIG_DIR` (default `~/.claude`), Codex from `CODEX_HOME` (default `~/.codex`). Argus models each folder as a context of its tool: the variable's exact value, or none for the default. The owner adds contexts in the manager, and they are kept in the app's defaults (`contexts.<tool>`). Every context's live login is read. The saved accounts stay global, one vault for all contexts. Each context is its own section in the popover and the manager. A switch writes its section's context only, and it is refused while the target account is live in another context of the same tool. Renewal skips an account live in any context. agy has no contexts. (tech-design §2, F-09)

## Why

The tools derive every store from the folder, and Claude Code derives its Keychain item from the variable's exact text. The Claude Code 2.1.303 bundle names the item `Claude Code-credentials-<first 8 hex of sha256(configHome)>` whenever `CLAUDE_CONFIG_DIR` is set, where `configHome` is the variable's value normalised to NFC (no `~` expansion, no symlink or trailing-slash cleanup). `oauthAccount` lives in `$CLAUDE_CONFIG_DIR/.claude.json`, and the refresh locks are `<configHome>/.oauth_refresh.lock` and `realpath(configHome).lock`. Unset, the item is plain `Claude Code-credentials` and the config is `~/.claude.json`. So `CLAUDE_CONFIG_DIR=$HOME/.claude` is a different login from the variable unset. This was checked against an existing context folder on the owner's Mac, whose item name matched the hash. Codex keeps `auth.json`, its keyring account (hashed from the resolved home) and its app-server daemon's `app-server-daemon/daemon.pid` under `CODEX_HOME`.

One login must not be live in two contexts. Both vendors rotate the refresh token at every renewal, and Codex's are single-use (ADR-0002). Two folders holding one login renew independently, because each has its own store and lock. The first renewal spends the token and leaves the other folder signed out. Separate sign-ins in each folder give each its own token chain, so the same account can be live in several contexts as long as Argus did not copy it there.

## Considered alternatives

- **Accounts per context (one vault each).** Rejected: the owner wants accounts global, and the same account would be polled and renewed once per vault.
- **Copy one login into several contexts and warn.** Rejected: the second context is signed out at its next renewal. Syncing rotated tokens across folders loses the race, because both copies expire together and Argus reads the stores only every few minutes.
- **Named profiles bundling a Claude folder and a Codex home.** Rejected: the CLIs choose their folders independently, so a per-tool list is simpler and complete.
- **One card per tool with a context picker** (0.3.0). Replaced: its hidden selection decided the card, Save, Switch and the menubar at once, while the rows still showed other contexts' logins.
- **Discovering contexts from `~/.claude*` folders or Keychain items.** Rejected: an item's hash can't be mapped back to a path. Manual entry with a live status per row shows a mismatched path at once.
- **agy through a `HOME` override.** Rejected: agy has no folder setting, and its Keychain item `gemini`/`antigravity` is the same whatever `HOME` is.

## Consequences

- A context's id is its exact path. A path naming the same folder as another context of the tool is refused: Claude paths are compared standardised, so `/x/` matches `/x`; Codex paths are compared resolved, including the default home. A leading `~/` is expanded, since the shell does that in an assignment.
- `ToolEnvironment.scoped(to:)` and `ToolAdapter.scoped(to:)` point the readers at a context. `AppState.live` is kept per tool, per context. `AppState.snapshot(_:)` is one context's section: its live login and the saved accounts live in no context. An account live in another context is listed only in that context's section, so it is never offered for a switch or suggested elsewhere. Show in menubar and Show in popover are kept per context, and a default context keeps its pre-context keys.
- Polling cost is unchanged: each account is fetched once per batch. When separate sign-ins put one account in several contexts, it is fetched with, and synced back from, the login whose access token lasts longest.
- Renewal re-reads every context inside the tool's exclusive section and skips an account live in any of them, or any account while a context's login is unknown, unsupported or incomplete. An API-key Codex login is the exception, because it holds no refresh token. A switch is paused the same way while another context's login is unknown.
- Removing a context stops Argus reading it, so removal is refused while the folder runs on the very login saved for its account and no other context has that account live: renewing the saved login would spend the folder's token. Two contexts whose logins share a refresh token, as with a copied Codex folder, are flagged on their rows.
- Each Claude context has its own switch journal (`vault/claude-switch-<suffix>.json`, the suffix being its Keychain item's), and every listed context's journal is settled at launch. A removed context's journal waits until that context is added again.
- A Codex switch restarts only the daemon its home recorded in `daemon.pid`. The default home falls back to the first running daemon when it recorded none (a Codex too old to write the file).
- The legacy Claude lock is now `realpath(configHome).lock`. That is `~/.claude.lock` as before unless `~/.claude` is a symlink, where it now matches Claude Code.
- The Claude Keychain account follows the same bundle: the login name when it is only letters, digits, `.`, `_` and `-`, else `claude-code-user`.
- Risk: a context whose Codex home uses keyring storage reads as unsupported, which pauses renewal of every saved Codex account, as the default context already does.
