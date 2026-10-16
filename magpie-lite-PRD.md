# PRD — magpie-lite: multi-account login vault, switcher and allowance monitor for Claude Code, Codex CLI and Antigravity CLI

**Source scope**: task summary + decisions settled in conversation on 2026-10-16 (two clarification rounds; amended the same day: saved-login storage, refresh interval, system-wide switch; amended again after the owner approved the final visual design: menubar format and per-tool visibility, Claude per-model weekly limits, collapsed popover, per-account refresh, running-low suggestion, remove with Undo); reference research digest (magpie, claude-swap, aisw, CodexBar, codex-account-switcher, AntigravityManager)
**Requirement ledger**: none — no source requirements document
**Operating envelope** (source: deployment in hand — the owner's own Mac; other fields unstated): horizon unstated · accounts: one local user holding 3–5 saved accounts per tool today (source: owner), i.e. up to ~15 accounts · largest entity at horizon: ~15 saved accounts · peak rate on hot path: bounded by vendor allowance endpoints, ~30 requests/hour per Claude identity (source: claude-swap poll policy) · maintainers: 1 · platform: single Mac, macOS 26 on Apple Silicon, personal build (no store distribution)
**Status**: implementation-ready

## Problem
The owner holds several subscription accounts for Claude Code, Codex CLI and Antigravity CLI (`agy`). Each tool keeps exactly one live login, stored differently (macOS Keychain, `auth.json`, Keychain envelope). Moving between accounts means signing out and back in, and signing out can revoke the very token being left. Nothing shows, at a glance, how much 5-hour and 7-day allowance remains on each account, so the owner discovers an exhausted window only when a session stops working.

## Solution
A native macOS menubar app. The menubar shows, for each tool the owner chooses to show, a small letter mark with the live account's 5-hour and 7-day remaining allowance stacked beside it. Clicking it opens a polished popover showing each tool's live account with its 5-hour and 7-day remaining allowance and reset times, the other saved accounts one click away with a one-click switch, and a suggestion to switch when the live account runs low while another saved account has headroom. A single simple management window lists the same accounts and lets the owner save the current live login of each tool, switch, and remove saved accounts. A background task keeps every saved account's allowance current — including accounts that are not live — and keeps their saved logins valid.

## User stories
1. As the owner, I want to see which account each tool is currently signed in as (identity and plan), so that I know which account a new session will use.
2. As the owner, I want to save the current live login of a tool into the app, so that I can return to that account later without signing in again.
3. As the owner, I want to be told when a tool's live login is not yet saved, so that I can save it before replacing it.
4. As the owner, I want to switch a tool to another saved account in one action, so that I avoid signing out and back in.
5. As the owner, I want the 5-hour and 7-day remaining allowance and reset time for every saved account of every tool, refreshed in the background, so that I can pick an account with headroom.
6. As the owner, I want the live accounts' allowance in the menubar, for the tools I choose, so that I see the state without opening anything.
7. As the owner, I want a popover from the menubar icon that shows all tools and accounts with allowance and a switch action, so that the common tasks take one click.
8. As the owner, I want one simple management window to save, switch and remove accounts, so that management stays in one place.
9. As the owner, I want an account whose saved login can no longer be renewed to be clearly marked, so that I know to sign in to it again.
10. As the owner, I want the app to start when I log in to my Mac, so that allowance monitoring is always running.
11. As the owner, I want to be told on the live account when it is running low and another saved account has headroom, with a switch to that account, so that I move before a session stops.
12. As the owner, I want to undo removing a saved account, so that a mis-click does not cost me a sign-in.

## Behavioral decisions
- **Adding accounts:** an account is added only by saving a tool's current live login. To add another account the owner signs in with the tool itself, without signing out first, then saves it in the app. The app runs no sign-in flow of its own.
- **Tools in scope:** Claude Code, Codex CLI, Antigravity CLI (`agy`). Each tool has at most one live account at a time; any number of saved accounts.
- **Switch = in-place, system-wide swap of the tool's live login.** Every new session of the tool on this Mac uses the new account. Only authentication state changes: the tool's credential, its identity metadata (Claude), and for `agy` the provider selection that makes it use the account login. The tool's settings, history, sessions, MCP configuration and other files are left byte-identical.
- **Sync-back before switch-away.** Immediately before a switch, the app re-reads the tool's live login and, when its identity matches a saved account, updates that saved copy (the tool may have renewed its tokens). A live login with no saved match is kept aside before it is replaced, never discarded.
- **Switch is all-or-nothing.** If any write fails, the tool's live login is restored to its exact pre-switch state and the switch reports failure. Switching to the account already live is a no-op.
- **Read failures are "unknown", never "empty".** If the app cannot read a tool's live login (denied, unreadable, unsupported storage mode), switching for that tool is refused and nothing is written.
- **Login renewal ownership — one holder per token.** The tool renews the live account's login; the app never renews it and only reads its current access token to fetch allowance. The app renews saved, non-live accounts itself and stores the renewed tokens before using them. When an account becomes live, the app stops renewing it; when it stops being live, the app resumes after sync-back.
- **Account identity.** Claude: email + organization. Codex: email + workspace (account id). `agy`: Google account subject. The same email in two organizations/workspaces is two accounts. Saving an already-saved identity updates it instead of duplicating it.
- **Allowance.** Shown per account as remaining percentage and reset time for the 5-hour window and the 7-day window. Windows are identified by their duration, not their position in the vendor response; a window the vendor does not return displays as "—". `agy` reports two model groups (Gemini; Claude and GPT), each with its own 5-hour and weekly window; both are shown. Claude reports, besides its all-models 5-hour and 7-day windows, weekly limits scoped to a single model (e.g. "Fable"); each is shown as its own weekly-only group under the all-models group. Group names are shown only when an account has more than one group.
- **Menubar:** for each shown tool with a live login, an outlined letter mark (C Claude, X Codex, G `agy`) with two stacked values beside it — the live account's 5-hour remaining on top, 7-day remaining below, as percentages. Each value is the lowest remaining across that account's groups for that window (`agy`: its two model groups; Claude: all-models and per-model weekly groups). A missing window shows `—`; a value under 15% is red; a tool whose live reading is stale is dimmed. When no tool is shown, or no shown tool has a live login, only the app icon appears. VoiceOver reads the values in words.
- **Show in menubar:** each tool has a "Show in menubar" switch in the management window; on for every tool by default; the choice persists across app restarts.
- **Popover layout:** each tool shows its live account; its other saved accounts are behind a "+N more" control that expands to show them and collapses with "Show less". Every account row has the same layout (5-hour and 7-day bars with remaining % and reset time per group); the live row is tinted and marked Live, the others carry Switch.
- **Running-low suggestion:** on the live account's row, when the live account's lowest window (a missing window counts as 100%) is under 15% and the best other saved account of that tool that is neither stale nor blocked (needs sign-in, app needs update, unreadable) has its lowest window at 40% or more, the row reads "Running low. <account> has <N>% left." with a Switch that switches to that account. It never switches by itself.
- **Remove with Undo:** removing a saved account acts at once, with no confirmation dialog; a banner reads "Removed <account>. Its saved login file was deleted." with Undo, which restores the saved login exactly as it was.
- **Appearance:** popover and management window follow the system light or dark appearance.
- **Launch at login:** a toggle in the management window registers the app as a login item; off by default.
- **Refresh interval:** a 3 / 5 / 10-minute choice in the management window; the choice persists across app restarts.
- **Freshness.** Allowance of every saved account, and of each tool's live login even before it is saved, is fetched automatically every 3, 5 or 10 minutes (owner's choice in the management window, default 5). On demand, "Refresh live accounts" fetches every tool's live account now, and each account row's refresh fetches that one account now. A vendor's rate-limit response postpones that vendor's next fetch beyond the chosen interval. On a failed fetch the last good reading stays visible, marked stale with its age.
- **Live account allowance.** Uses the tool's current access token, read-only. If that token has expired, the last reading stays visible and is marked stale until the tool renews it.
- **Needs sign-in.** When renewal of a saved account is permanently refused by the vendor, the account is marked "needs sign-in", its polling stops, and switching to it is disabled with that reason shown.
- **Post-switch pick-up.** The app tells the owner when a running process keeps the old account: Claude Code sessions pick up the new login within about 30 seconds or on a new session; a running Codex app-server or Codex desktop app needs a restart (offered by the app); `agy` uses the new login on its next session.
- **Secrets.** Saved logins never leave the Mac. They are stored as owner-only files (0600, in a 0700 folder in the app's Application Support directory) that are excluded from Time Machine, and they never appear in the UI or logs.
- **Unsupported storage modes fail closed.** A Codex install configured for keyring-only or ephemeral credentials (when the app cannot read it) is shown as unsupported for switching rather than switched blindly.

## Acceptance criteria
- [ ] With Claude account A live and B saved, switching to B results in: Claude Code's live credential holding B's login; the identity metadata naming B; every other key of Claude Code's global config byte-identical; A's saved copy equal to A's last live credential; and a fresh `claude auth status --json` reporting B's email. (Req: — design)
- [ ] With Codex account A live and B saved, switching to B results in Codex's live login identifying B (email + workspace), the file permission owner-only, every other file under the Codex home unchanged, and a fresh Codex process using B. (Req: — design)
- [ ] With `agy` account A live and B saved, switching to B results in `agy`'s Keychain credential holding B's login in the envelope format `agy` reads, every `agy` setting other than the provider selection unchanged, and a fresh `agy` process authenticating as B. (Req: — design)
- [ ] Switching A → B → A for each tool, using real accounts on the owner's Mac, leaves each tool working on A with a successful model response, and no other tool's credential or settings files change. (Req: — design)
- [ ] Switching to the account that is already live performs no write. (Req: — design)
- [ ] When a write during a switch fails (injected), the tool's live login is byte-identical to its pre-switch state and the UI reports the failure. (Req: — design)
- [ ] When the live login cannot be read (injected denial), the switch is refused and no store is written. (Req: — design)
- [ ] Saving the live login of an identity that is already saved updates that entry; the account list length is unchanged. (Req: — design)
- [ ] Two Codex logins with the same email and different workspaces are listed as two accounts; removing one leaves the other's saved login intact. (Req: — design)
- [ ] When a tool's live identity is not saved, the popover and window show it as unsaved with a save action; after saving, the unsaved marker disappears. (Req: — design)
- [ ] Every saved account shows 5-hour and 7-day remaining % and reset time when the vendor returns those windows; a missing window shows "—". Remaining is computed as 100 − utilization (Claude), 100 − used percent (Codex), remaining fraction × 100 with a missing fraction treated as 0 (`agy`). (Req: — design)
- [ ] A Codex response whose only window is 7 days shows that value in the 7-day column and "—" for 5-hour. (Req: — design)
- [ ] Readings update without owner action within one polling cycle; when a fetch fails, the previous reading remains with a stale marker and its age. (Req: — design)
- [ ] When a saved, non-live account's access token has expired, the app renews it before fetching, stores the renewed tokens, and a later switch to that account succeeds with them. (Req: — design)
- [ ] The app sends no token-renewal request for any tool's live account (verified with a recording HTTP stub across a full polling cycle and a switch). (Req: — design)
- [ ] A permanent renewal refusal marks the account "needs sign-in", stops its polling, and disables switching to it with the reason shown. (Req: — design)
- [ ] The menubar shows, per shown tool with a live login, its letter mark with the live account's 5-hour value above its 7-day value as percentages, `—` for a missing window, omits a tool with no live login or switched off, shows only the app icon when nothing remains, and changes when a reading, a tool's live account, or a Show-in-menubar switch changes. (Req: — design)
- [ ] With `agy` group remainders Gemini 45/90 and Claude-and-GPT 30/95, the `agy` menubar values read 30% over 90%; with Claude all-models 62/40 and a Fable weekly-only group at 28, the Claude values read 62% over 28%. (Req: — design)
- [ ] A menubar value under 15% is red and a value of 15% or more is not; a tool whose live reading is stale is dimmed while the other tools are not. (Req: — design)
- [ ] Switching a tool's "Show in menubar" off removes that tool from the menubar at once, and the choice survives an app restart. (Req: — design)
- [ ] A Claude usage response carrying a model-scoped weekly limit shows that model as its own group with 7-day remaining = 100 − its percent and 5-hour "—"; a response without such limits shows only the all-models windows. (Req: — design)
- [ ] With the live account's lowest window at 12% and another saved, fresh, unblocked account at 71%, the live row shows "Running low. <that account> has 71% left." and its Switch switches to that account; with the best other account at 39%, or only stale or blocked others, no suggestion shows. (Req: — design)
- [ ] The popover shows only each tool's live account until "+N more" is pressed, then all its saved accounts until "Show less". (Req: — design)
- [ ] An account row's refresh fetches that account only; "Refresh live accounts" fetches every tool's live account only; neither changes the automatic interval. (Req: — design)
- [ ] Removing a saved account deletes its saved login file at once and shows Undo; Undo brings back the account with a saved login byte-identical to the removed one. (Req: — design)
- [ ] Enabling launch at login makes the app start at the next login; disabling it stops that. (Req: — design)
- [ ] Removing a saved account deletes it from the app and from the list views; the tool's live login is unchanged, including when the removed account is the live one. (Req: — design)
- [ ] After switching Codex while a Codex app-server or Codex desktop app is running, the app shows that it still uses the old account and offers a restart. (Req: — design)
- [ ] No token, refresh token or credential value appears in the UI, in logs, or in any file outside the app's owner-only vault files and the tools' own stores; every vault file is mode 0600 inside a 0700 folder marked excluded from backup. (Req: — design)
- [ ] Choosing 3, 5 or 10 minutes sets the automatic fetch interval and the choice survives an app restart. (Req: — design)

## Testing intent
- **External behavior that proves it:** the tool's own CLI reports the new identity after a switch; vendor allowance values parsed into the displayed numbers; stores byte-compared before/after.
- **Critical integration points:** each tool's live credential store (Keychain items and files, including Keychain access by the tool after the app writes), the three vendors' token-renewal endpoints, the three allowance endpoints.
- **Granularity:** unit tests for response parsing (window by duration, missing fields, remaining-percent math) and identity extraction, using recorded vendor responses; integration tests for switch transactions against a temporary home directory and a disposable Keychain that is never added to the owner's search list, with injected failures; HTTP-stubbed tests for renewal ownership and rate-limit backoff; a real-account A → B → A acceptance per tool on the owner's Mac.
- **Prior art (reference repositories, not this repo — greenfield):** aisw's disposable-keychain and native-canary tests and its A→B→A acceptance record; claude-swap `tests/test_oauth.py` (usage parsing, renewal body, active-account never renewed) and `tests/test_switcher.py` (lock protocol, rollback, wiped-credential guard); magpie's Codex usage fixtures (`codex_usage_pro_credits.json`, `codex_held_test.go`) and Antigravity quota-summary fixtures; CodexBar `AntigravityQuotaSummaryTests.swift`.
- **Ripple set — switch tool T from A to B:** T's live credential; T's identity metadata (Claude) / provider selection (`agy`); A's saved copy (sync-back); which account is marked live; popover and window live markers; menubar values; renewal ownership (A → app, B → tool); allowance attribution of the next reading; running-process pick-up notice.
- **Ripple set — save current login:** saved account list (new or updated entry); unsaved marker; popover and window rows; polling schedule includes the account.
- **Ripple set — remove account:** saved account list; popover and window rows; menubar values if it contributed; polling stops; T's live login unchanged; Undo banner. **Undo:** the saved login restored byte-identical; account list, rows and polling as before the remove.
- **Ripple set — Show in menubar:** menubar content; spoken label; persisted choice; sidebar marker in the management window.
- **Ripple set — running-low Switch:** identical to switch tool T from A to B.
- **Ripple set — background renewal of a saved account:** its saved tokens; its status (ok / needs sign-in); its next allowance reading.
- **Write tree:** allowance readings → popover rows, window rows, menubar values, running-low suggestion; Show-in-menubar choice → menubar content; account status → badge in popover and window; renewed tokens → read by the allowance fetcher and by the next switch; plan/tier → account label in popover and window; switch outcome and pick-up notice → popover/window message.

## Out of scope
- Gemini CLI and the Antigravity IDE remain unchanged; only `agy`'s login is managed.
- Reducing token consumption (compression, proxying) is not part of this product.
- Spend/cost tracking, credits and extra-usage are a later phase; only 5-hour and 7-day allowance is shown, including Claude's model-scoped weekly limits.
- Running two accounts of one tool side by side (per-account config directories) is a later phase.
- Custom account labels are a later phase; accounts are labelled by identity and plan.
- In-app sign-in flows are a later phase; accounts enter the app by saving the tool's live login.
- System notifications for low allowance and automatic switching are a later phase; the in-popover running-low suggestion is the only low-allowance prompt.
- Windows and Linux remain unsupported; distribution beyond the owner's Mac is a later phase.

## Notes
- **Visual reference:** the owner approved the final visual design (menubar, popover, states, management window, light and dark) on 2026-10-16; its snapshot travels with the technical design pack.
- **Risk — Antigravity account suspension (accepted by owner):** Google may suspend an Antigravity account it sees used outside Antigravity; the app's allowance and renewal calls use Antigravity's client identity. Read-only calls, but the risk is non-zero.
- **Risk — undocumented contracts:** all three allowance endpoints and the `agy` Keychain envelope are private vendor contracts and can change without notice; parsing must degrade to "unknown/stale", never crash or corrupt a store.
- **Assumption — Google token renewal:** whether Google rotates `agy` refresh tokens on renewal is unresolved in the references; it must be verified against a real account before relying on either behavior.
- **Amendment (2026-10-16, design review):** the menubar moved from a one-line `C 62/40 · …` text to per-tool stacked values with a per-tool show switch; Claude's model-scoped weekly limits moved into scope; the refresh action now covers live accounts, with a per-account refresh; the popover collapses each tool to its live account; a running-low suggestion and remove-with-Undo were added.
- **Amendment (2026-10-16):** saved logins moved from the macOS Keychain to owner-only files at the owner's request — avoids Keychain prompts on every rebuild of an ad-hoc-signed app; precedent: Codex's own `auth.json` and CodexBar's token store are 0600 files.
- **Constraint:** writing another tool's Keychain item through the native Keychain API can lock that tool out of its own credential; the tool's own access path must be preserved (reference: aisw ADR 0004).
- **Constraint:** signing out from a tool (e.g. Claude Code `/logout`) revokes that login's refresh token, which kills its saved copy; owner-facing guidance must say to sign in to the next account without signing out first.
