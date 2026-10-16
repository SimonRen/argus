# Frontier — magpie-lite

pack_schema: 1
status: ready
grounded_at: a03033d9575ef842084c1d4282ae1d8932deeb0b
verified_at: df7e0fb616b894e72fef1e3779399bf1f19d26af
pack_commit: eb0bc95 (amended in place to record this line; the final sha is the branch commit titled "Add magpie-lite design pack")
source_prd: magpie-lite-PRD.md (amended 4ea16f6, design-review amendment 6b597ab; final-review amendment c88ba0b, close-review amendment 5a87e03, wording df7e0fb)
ledger: none — no source requirements document
round: 13
close_passes: 2/2
compiled_from_round: 13
accepted_unground: []

## Greenfield adaptation
The target repository holds only `.gitignore` and the PRD at `grounded_at`; the four repository lenses return command-backed `none-found`. External contracts the app must consume (each tool's credential store, token and allowance endpoints) and reference implementations are grounded against pinned clones under `refs/` (gitignored):

| Ref | Commit | Origin | Licence |
|---|---|---|---|
| magpie | 63be4771 | github.com/yetone/magpie | MIT |
| claude-swap | 8fdc89a3 | github.com/realiti4/claude-swap | MIT |
| aisw | 8faa0553 | github.com/burakdede/aisw | MIT |
| CodexBar | 667dd3a5 | github.com/steipete/CodexBar | MIT |
| codex-account-switcher | 3835b13e | github.com/liuzhao1225/codex-account-switcher | MIT |
| AntigravityManager | ccec07e1 | github.com/Draculabo/AntigravityManager | CC BY-NC-SA 4.0 — facts only, no code reuse |

**Candidate scope (greenfield):** every path is `create`. The `create` join's "parent directory exists" holds for the scaffold rows at the repository root (`Package.swift`, `Makefile`, `Resources/…` under F-05); every `Sources/…` and `Tests/…` path's parent is created by that scaffold slice, which plan-seed order puts first.

Rows tagged **[mac]** were observed on the owner's Mac on 2026-10-16 (macOS 26.6.2, Claude Code 2.1.301, codex-cli 0.163.0, agy 1.3.6) — metadata and key names only.

## Features
| F | Title | Story | Status |
|---|---|---|---|
| F-01 | Live login detection (identity, plan, unsaved marker) | PRD stories 1, 3 | active |
| F-02 | Save current live login to the vault | PRD story 2 | active |
| F-03 | Switch a tool's live account | PRD story 4 | active |
| F-04 | Allowance monitoring and saved-account renewal | PRD stories 5, 9 | active |
| F-05 | Menubar status item (stacked per-tool values, Show in menubar) | PRD stories 6, 11 | active |
| F-06 | Popover (collapsed per tool, running-low suggestion) | PRD stories 7, 11 | active |
| F-07 | Management window (save, switch, remove with Undo, Show in menubar) | PRD stories 8, 11, 12 | active |
| F-08 | Launch at login | PRD story 10 | active |

## Priority (owner, 2026-10-16)
"The most important feature is the allowance viewer and the ability to switch account."
- **Core:** F-04 allowance monitoring (surfaced by F-05 menubar and F-06 popover) and F-03 switching.
- **Prerequisite of core:** F-01 live login detection, F-02 save current login (switching needs a vault).
- **Secondary:** F-07 management window, F-08 launch at login.
Branch order in hardening and plan-seed order at close follow this priority, then risk.

## Grounding ledger
| Lens | Status | Rows | Evidence |
|---|---|---|---|
| decision archaeology | none found | `ls docs/adr CONTEXT.md CLAUDE.md` → 0 / 0 files at a03033d | repo holds `.gitignore`, PRD only |
| (a) seams + contracts | done | target repo: `git ls-files \| xargs rg -l '\.swift$'` → 0 matches / 1 file (PRD excluded); external contracts + reference code R-01..R-30 | grounding.md |
| (b) conventions + tests | done | C-01..C-06 (user-instruction); target repo tests: `git ls-files \| xargs rg -l 'XCTest\|import Testing'` → 0 matches / 1 file; external prior art T-01..T-07 | grounding.md |
| (c) schema + lifecycle | done | target repo: `git ls-files \| xargs rg -l 'migration\|schema\|CREATE TABLE'` → 0 matches / 1 file; persisted-data contracts of the tools R-01, R-02, R-06, R-11, R-12 | grounding.md |
| (d) reference trace | done | CodexBar Claude allowance path (status item → loop → fetch → parse → card → error path → test) | grounding.md |

## Branch ledger
| # | Branch | F | Bucket | local_fact | Landed |
|---|---|---|---|---|---|
| B-01 | saved-login storage medium | F-02, F-04 | covered | settled: PRD §Secrets (amended 2026-10-16, owner choice: 0600 files); R-24 | tech-design §3 |
| B-02 | refresh interval choices and default | F-04 | covered | settled: PRD §Freshness (amended, owner choice 3/5/10, default 5) | tech-design §5 |
| B-03 | switch scope: system-wide live login | F-03 | covered | settled: PRD §Switch (amended, owner confirmed); R-01, R-06, R-11 | tech-design §4 |
| B-04 | menubar shell: NSStatusItem + NSPopover vs MenuBarExtra vs NSStatusItem + NSMenu | F-05, F-06 | decided | tradeoff-remains: R-17, R-18, R-27 | tech-design §6 · DEC-01 |
| B-05 | build: SwiftPM + Makefile vs Xcode project | cross-cutting | decided | tradeoff-remains: R-25, C-01 | tech-design §1 · DEC-02 |
| B-06 | visual design direction (incl. low-value colouring) | F-05, F-06, F-07 | decided | tradeoff-remains: C-06 (owner-approved design snapshot `ui/`), R-17, R-18, R-30 | tech-design §6 · DEC-10 · DEC-11 (DEC-01 narrowed) |
| B-07 | Codex saved-account renewal: app-owned HTTP vs CLI-delegated per-account CODEX_HOME | F-04 | decided | tradeoff-remains: R-08, R-21 | tech-design §5 · DEC-03 · ADR-0002 |
| B-08 | Claude saved-account renewal mechanism | F-04 | covered | settled: R-03, T-02 (direct renewal by the vault owner; live account never renewed) | tech-design §5 |
| B-09 | agy OAuth client secret source: embedded constant vs read from installed Antigravity app | F-04 | decided | tradeoff-remains: R-13, R-22 | tech-design §5 · DEC-04 |
| B-10 | Google refresh-token rotation | F-04 | covered | settled: R-13, R-22 (two implementations ignore a returned refresh_token); defensive write-back; re-checked at real-account acceptance | tech-design §2 |
| B-11 | switching away from an unsaved live login: auto-save vs keep aside vs block | F-01, F-03 | decided | tradeoff-remains: claude-swap stashes unclaimed logins (`claude-swap/src/claude_swap/credentials.py:1569-1591`) | tech-design §4 · DEC-05 |
| B-12 | Codex keyring / auto / ephemeral store modes | F-01, F-03 | covered | settled: PRD §Unsupported storage modes; R-06 | tech-design §2 |
| B-13 | Claude switch honours Claude Code's lock protocol | F-03 | covered | settled: R-05 | tech-design §4 |
| B-14 | transport for writing tools' Keychain items | F-02, F-03 | covered | settled: R-16 | tech-design §2 |
| B-15 | agy switch: Keychain item only vs Keychain + token file | F-03 | decided | tradeoff-remains: R-11 (aisw writes keyring only; AntigravityManager writes both) | tech-design §4 · DEC-06 |
| B-16 | Codex post-switch restart: automatic vs offered | F-03 | covered | settled: PRD §Post-switch pick-up; R-10, R-20 | tech-design §4 |
| B-17 | Claude allowance request User-Agent | F-04 | decided | tradeoff-remains: R-04 (`claude-swap/1.0`), R-19 (`claude-cli/<ver> (external, cli)`) | tech-design §5 · DEC-07 |
| B-18 | concurrency model | cross-cutting | decided | tradeoff-remains: R-25, R-26 | tech-design §1 · DEC-08 · ADR-0003 |
| B-19 | vault file layout, format, atomic write and locking | F-02, F-03, F-04 | decided | tradeoff-remains: R-24, R-20 | tech-design §3 · DEC-09 · ADR-0001 |
| B-20 | reading tools' live Keychain items: `/usr/bin/security` vs SecItem | F-01, F-04 | covered | settled: R-28 ([mac] prompt-free rc 0 for both items) | tech-design §2 |
| B-21 | Claude model-scoped weekly limits (design shows a "Fable" group) | F-04, F-05, F-06 | covered | settled: PRD §Allowance (design-review amendment); R-29, T-07 (three references parse `limits[]` alike) | tech-design §5 · FR-04.18 |
| B-22 | Claude menubar value with several groups | F-05 | covered | settled: PRD §Menubar (lowest across groups — the design's own computation, 62/40 + —/28 → 62/28) | tech-design §6 · FR-05.2 |
| B-23 | what on-demand refresh covers (design: header "Refresh live accounts", per-row refresh) | F-04 | covered | settled: PRD §Freshness (design-review amendment); automatic polling still covers every saved account | tech-design §5 · FR-04.19, FR-04.20 |
| B-24 | Show-in-menubar default | F-05 | covered | settled: PRD §Show in menubar (on for every tool; the design's agy-off is mock state) | tech-design §6 · FR-05.8 |
| B-25 | Remove / Undo / Save versus in-flight renewal and switch (close pass 1 review) | F-02, F-07 | decided | tradeoff-remains: ADR-0003, R-24 | tech-design §1, §3 · DEC-08 · ADR-0003 consequences · FR-07.2, FR-07.5 |
| B-26 | switch rollback scope: live stores only vs vault too (close pass 1 review) | F-03 | decided | tradeoff-remains: ADR-0001 (`.prev` forensic: older bytes may hold a spent refresh token) | tech-design §4 · FR-03.10 |
| B-27 | renewal decision and fetch de-duplication across the section boundary (close pass 1 review) | F-04 | decided | tradeoff-remains: R-03, R-08, ADR-0003 | tech-design §1, §5 · DEC-08 · FR-04.7, FR-04.21 |
| B-28 | needs-sign-in recovery and unsaved live login polling (close pass 1 review) | F-04, F-05 | decided | tradeoff-remains: PRD story 9, PRD §Live account allowance | tech-design §5 · FR-04.4, FR-04.22, FR-04.23 |
| B-29 | stale dimming: whole item vs per segment (close pass 1 review) | F-05 | decided | tradeoff-remains: C-06 (design shows one stale bar; per-tool scope unspecified) | tech-design §6 · DEC-10 · FR-05.4 |
| B-30 | Keychain write size: `security -i` 4096-byte stdin line vs agy 2223-byte envelope (close pass 1 review) | F-03 | decided | tradeoff-remains: R-16 (claude-swap argv fallback, aisw reject), R-28 sizes; owner chose the argv fallback 2026-10-16 | tech-design §2 · DEC-12 · FR-03.16 |
| B-31 | incomplete entries: renew, fetch, switch? (close pass 1 review) | F-03, F-04 | decided | settled: FR-03.6, FR-03.11 (an incomplete identity can never verify) | tech-design §5 · FR-03.12, FR-04.7 |
| B-32 | renewal while a tool's live state is unknown / unsupported / incomplete (close pass 2 review) | F-04 | decided | settled: PRD §Login renewal ownership (liveness unprovable → no renewal) | tech-design §5 · FR-04.7 · ADR-0002, ADR-0003 consequences |
| B-33 | refusal status codes per vendor (close pass 2 review) | F-04 | decided | settled: ADR-0002 (Codex 400/401), R-03 (Claude `invalid_grant`), R-08 (`magpie/internal/provider/account.go:826-837`: 403 is transient) | tech-design §5 · FR-04.9, FR-04.10 |
| B-34 | which writes clear app needs update (close pass 2 review) | F-04 | decided | settled: DEC-04, FR-04.11 (client block lasts until relaunch) | tech-design §5 · FR-04.22 |
| B-35 | polling a live account whose saved entry is blocked; Save of an incomplete identity (close pass 2 review) | F-01, F-02, F-04 | decided | settled: PRD §Freshness, §Live account allowance; FR-01.8 | tech-design §5 · FR-04.4, FR-01.9, FR-02.4, FR-06.10 |
| B-36 | Claude live login spans two stores: consistent read (close pass 2 review) | F-01, F-04 | decided | settled: R-01, R-02, R-05 (Claude Code's locks cover refresh and config writes, not a joint Keychain + config write) | tech-design §2 · FR-01.10, FR-04.25 |
| B-37 | poll-time sync-back of a saved live account (close pass 2 review; owner approved 2026-10-16) | F-04 | decided | settled: PRD §Sync-back (final-review amendment) | tech-design §5 · FR-04.24, FR-04.25 · ADR-0003 consequences |
| B-38 | Claude switch: span of Claude Code's lock protocol (reset close pass 1 review) | F-03 | decided | settled: R-05 (Claude Code renews under its credential locks; steps 2–5 do no network) | tech-design §4 · FR-03.7, FR-03.11 |
| B-39 | poll-time sync-back: in-section re-read; Claude consistency guard (reset close pass 1 review) | F-04 | decided | tradeoff-remains: R-01, R-02, R-05 (no grounded bound on the tool's Keychain-to-config gap → two agreeing polls instead of a 2 s double read) | tech-design §5 · FR-04.24, FR-04.25 · ADR-0003 consequences |
| B-40 | `invalid_client` scope: renewal vs live-token fetch; FR-04.10 / FR-04.11 overlap (reset close pass 1 review) | F-04 | decided | settled: DEC-04, R-13 | tech-design §5 · FR-04.10, FR-04.11 |

## Current round
branch: — · stage: all branches terminal.
Close pass 1 (2026-10-16): failed — citation re-resolution found 3 moved rows (fixed at source: R-17, R-18, R-24) and 1 unverifiable version string (removed from C-06); the integration review returned substantive findings (baked in round 11 as B-25 … B-31); the tree outside the pack is dirty only with the uncommitted PRD design-review amendment. Owner approved the PRD amendment (committed 6b597ab). Close pass 2 (the last) entered.
Close pass 2 (2026-10-16): failed — the integration review returned substantive findings; `close_passes` 2/2 consumed → BLOCKED. Known: projections compile, all deterministic joins pass, the tree outside the pack is clean; citation re-resolution: 230 resolve, 4 moved (fixed at source: R-19, R-21, T-06, reference trace), 0 missing. Open findings (each changes an FR row; none reopens an owner decision):
- S1 renewal while the tool's live state is unknown / unsupported / incomplete can renew a live account (FR-04.7, ADR-0002, ADR-0003).
- S2 fresh live bytes clear app-needs-update, contradicting the until-relaunch client block (FR-04.22 vs FR-04.11, DEC-04).
- S3 Codex refusal = 400/401 regardless of body (ADR-0002, R-08) vs FR-04.9's `invalid_grant` + 403; no catch-all for other 4xx (FR-04.10).
- S4 a live account whose saved entry is needs-sign-in is never polled (FR-04.4, FR-04.9 vs PRD §Freshness, FR-04.13).
- S5 an incomplete live identity gets the unsaved banner and Save, creating an unusable entry (FR-01.9, FR-06.10, FR-02.4).
- Editorial: Glossary exclusive section; §3 Save in the section; ADR-0001 "never parsed on the switch path" vs Claude MCP-key composition (FR-03.7); FR-04.23 Claude identity spans two stores; FR-03.10 notice wording; FR-06.4 incomplete; AC-2 / AC-4 wording; PRD §Running-low still counts a missing window as 100 %.
What unblocks: the owner authorizes a round-12 bake of these fixes and resets `close_passes` to 0/2.
Owner authorized round 12 and the reset on 2026-10-16, and approved poll-time sync-back; round 12 baked as B-32 … B-37. Owner approved the final-review PRD amendment (committed c88ba0b). Close pass 1 of the reset entered.
Reset close pass 1 (2026-10-16): failed — citation re-resolution clean (232 resolve, 0 moved, 0 missing); the integration review returned substantive findings (Claude lock span; poll-time sync-back re-read and Claude guard; FR-04.10 / FR-04.11 overlap), baked in round 13 as B-38 … B-40 with the editorial fixes. The round-13 PRD wording (Claude two-poll sync-back; needs-sign-in polling scope) was approved and committed (5a87e03). Reset close pass 2 (the last) entered.
Reset close pass 2 result (2026-10-16): citation re-resolution clean (248 resolve, 0 moved, 0 missing; 32 candidate paths absent); joins pass; tree outside the pack clean at entry; integration review: two of three reviewers found no substantive issue; the third rated the Claude sync-back trigger substantive (an on-demand refresh could act as the second agreeing poll) — treated as a terminology clarification of B-39's interval-separated guard and the PRD's "two polls", fixed at source with the other editorial items. Pass clean, pending the owner's approval of that classification, the PRD wording commit and the pack.
Owner approved all on 2026-10-16: the classification, the PRD wording commit (df7e0fb) and the pack. Status ready.
