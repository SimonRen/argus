# Manager window redesign: implementation handover

Date: 2026-11-17. Scope: the manager window only, plus a new Settings window and an Add context sheet.

## Scope and hard constraints

- **The menu bar popover does not change.** No visual or behavioural change to `PopoverView.swift`, `StatusItemController.swift`, `MenuBarSummary.swift`, or the popover-facing parts of `RowModel.swift` (`ToolCard`, `AccountRow.windows`, `cells(_:)`, `subtitle`, `Suggestion`).
- `PopoverView.swift` also defines components the manager uses: `ToolMark`, `ContextChip`, `Chip`, `BadgeView`, `ActivityPill`, `PillButton`, `HoverStyle`, `RefreshButton`. Do not change their appearance. If the manager needs a different look, add a parameter with the current look as default, or add a new manager-only view.
- `Theme.swift` is shared with the popover. **Add tokens; do not change the value of any existing token.**
- No behaviour of save, switch, remove, undo, refresh, contexts, polling or preferences changes. This is a re-layout: every command and every piece of state that exists today still exists, in a new place.
- Light and dark must both work. The mockups are dark only; light uses the existing light tokens plus the new ones below.
- Repo rules in `CLAUDE.md` apply: UI logic in `ArgusCore` view models with tests, `make check` green, docs and changelogs updated (see the last section).

## Files in this folder

| File | What it shows |
| --- | --- |
| `Manager.dc.html` | The manager window, Claude Code / Default selected, with a toast |
| `Settings.dc.html` | The new Settings window |
| `AddContext.dc.html` | The new Add context sheet |

These replace `../Manager.dc.html` as the reference for the manager window. Read them as source: every size, weight and spacing is an inline style. Sizes in px map 1:1 to points.

Where a mockup and this document disagree, this document wins. Known differences:

- **Surface colours.** The mockups use approximations (`#1b1b1e`, `#222226`, `#232327`…). Use the existing `Theme` tokens for every surface, hairline and text colour (`win`, `side`, `tableCard`, `thead`, `soft`, `hair`, `text`, `sub`, `ter`).
- **Tool icons.** The lettered tiles (C, X, A) are placeholders. Keep `ToolMark`.
- **Title row.** The mockup draws traffic lights and a toolbar by hand. Keep the native unified title bar (`navigationTitle`, `navigationSubtitle`, `.toolbar`, `sceneBridgingOptions`) exactly as wired today.
- **Window size.** Keep 1080×720 default and 1000×560 minimum.

## What moves where

| Today | After |
| --- | --- |
| Toolbar: "Refresh every" segmented picker | Settings window |
| Toolbar: "Launch at login" toggle | Settings window |
| Toolbar: Updates menu (Check for Updates…, Check Automatically) | Settings window |
| Toolbar: refresh button | Stays. Add a Settings button after it |
| `loginItem.message` strip above the window content | Settings window, under the Launch at login row |
| Sidebar: flat "PROVIDERS" list, tool name per row, two unlabelled percentages, menubar glyph | Grouped by tool; rows are contexts; one percentage with its window label; glyph removed |
| Detail header: "Show in" Menubar / 5h / Popover toggle group | "Show this context in" card below the accounts table |
| Detail header: Save current login (always filled blue) | Stays in the header; filled only when the live login is not saved |
| Save banner, notice banner, undo banner (inline, push the table down) | Toast stack overlaid at the bottom of the detail area |
| Table: "5 H WINDOW" / "7 D WINDOW" columns, each stacking one bar per group | One column per window, one meter per cell |
| Row actions: Switch, refresh icon, trash icon | Switch (filled), then a "•••" menu holding Refresh and Remove |
| Large "No saved accounts" empty state | One hint row at the bottom of the table, always shown |
| Contexts card: list of contexts with status and trash | Removed. Contexts are the sidebar rows; path, warning and Remove live on each context's own page |
| Contexts card: inline add row (name, path, Choose…, Add) | Add context sheet, opened by "+" in the sidebar group header |

## Theme additions

Add to `Theme`, leaving existing tokens alone:

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `action` | `0x2F6FE0` | `0x2A66D9` | Fill of primary buttons with white text (Switch, Add context, unsaved Save current login) and of "on" switches if custom-drawn. The existing dark `ok` (`0x5B9BFF`) under white text is about 2.7:1; `action` is above 4.5:1 |
| `meter` | `0x4A4A50` | `0xD8D8DE` | Meter fill for the `.ok` band in the manager |

Add `func meterBar(_ band: Band) -> Color`: `.ok` → `meter`, `.warn` → `warn`, `.low` → `low`, `.empty` → `track`. The manager uses `meterBar`; the popover keeps `bar` and `cellFill`.

Percentage text colour in the manager (table cells and sidebar): `.ok` → `text`, `.warn` → `warnText`, `.low` → `barLow`, `.empty` → `ter`.

The idea: meters are neutral until a limit is close, so colour means "look here". Blue means an action or the live account, as it does today (`liveBg`, `liveText`, `liveRow` unchanged). Band thresholds (`band(_:)`) do not change.

## Sidebar

Reference: the `<nav>` in `Manager.dc.html`. Width 250 as today.

- Remove the "PROVIDERS" label. For each `Tool.allCases`, a group:
  - **Group header**, height 28: `ToolMark(size: 18)`, the tool's `displayName` (12 semibold, `sub`), and, when `tool.supportsContexts`, a 22×22 plain "+" button (`plus`, accessibility label "Add a \(displayName) context") that opens the Add context sheet for that tool.
  - **One row per `state.contexts(tool)`**, height 48, corner radius 8, selected background `soft`:
    - Line 1: `context.name` (13, semibold when selected, else medium).
    - Line 2: live email or "Not signed in" (11.5, `sub`, one line, tail truncation).
    - Trailing, right-aligned: the tightest percentage (13 semibold, monospaced digits, coloured by band as above) over its window label (10.5, `ter`).
- 18 pt between groups, 2 pt between rows in a group.

### Model change: `ManagerSidebarRow`

Replace `fiveHour` / `sevenDay` with the single tightest window of the live account:

- `tightest: (percentText: String, label: String, band: Band)?`, or an equivalent small struct.
- Source: the live account's present windows after `hidingMinorGroups`, the same set as today. Pick the one with the lowest `remaining`. Ties go to the earlier window in `AccountRow.windows` order.
- `percentText` is the used share, formatted as `WindowCell.percentText` ("47%"). `label` is that window's `WindowCell.label` ("5h", "7d", "Fable 7d").
- No live login, or no window: show "—" in `ter` and no label.
- `showsMenubarGlyph` is no longer drawn. Remove it if nothing else reads it.

Update the existing `ManagerSidebarRow` tests and add cases: lowest of several windows wins, tie order, minor agy groups ignored, not signed in, signed in with no reading.

## Detail page

Padding 24 horizontal, 22 vertical as today; 26 pt between the header, the table and the display card.

### Header

- `ToolMark(size: 32)`, tool name (keep 18 bold), `ContextChip` when `card.contextName != nil`. On the Default context of a tool with several contexts the chip reads "Default", as today.
- Subtitle line (12, `sub`): `ManagerText.header(snapshot)`, then for tools that support contexts a "·" and the assignment in monospaced 11 `ter`: `context.assignment ?? "\(variable) unset"`, middle truncation, text selection enabled. This is the string the Contexts card showed.
- **Context warning line**, shown under the subtitle only when needed (12, `warnText`, up to 3 lines). Add `ManagerText.contextWarning(_ live: LiveState?, context: ToolContext, sharedWith: ToolContext?) -> String?` in `ArgusCore`:
  - Returns `nil` when the context is signed in with a complete identity and `sharedWith == nil`, and when `live == nil`.
  - Otherwise returns what `contextStatus` returns today (shared login, unreadable account, "must be exactly this path", API key, unsupported storage).
  - Keep `contextStatus` and its tests; add tests for `contextWarning`.
- Trailing controls, right to left:
  - **Save current login**: height 30, radius 9, 12 semibold. Filled `action` with white text when the live login is signed in and not saved (the "— not saved" case of `ManagerText.header`); otherwise `btn` background with `text`. Pending and disabled behaviour unchanged (`card.pending`, "Saving…" text, 0.6 opacity).
  - **"•••" menu**, only when `!selected.isDefault`: one item, "Remove Context…", calling `commands.removeContext(selected)` with today's handling (wait state, error text, select `.default(tool)` on success). Keep the help text "Forget this context; its folder and logins stay". A removal error shows as a problem toast.

### Accounts table

Reference: the `<section aria-label="Accounts">` in `Manager.dc.html`.

- Columns come from `card.columns` (already built for the popover, do not change it) and cells from `row.cells(card.columns)`.
- Layout: account column weight 1.3, each window column weight 1, action column fixed 132, gap 28, horizontal inset 20. Update the private `Columns` struct to take the window-column count. Keep `ManagerLayout.fittingTableWidth`.
- **Header row**, height 36, `thead` background, 11.5 semibold `ter`, not uppercased, no kerning: "Account", then one title per column. Add `ManagerText.columnTitle(_ label: String) -> String` in `ArgusCore`: replace a trailing "5h" with "5-hour" and a trailing "7d" with "7-day", then append " used". Examples: "5h" → "5-hour used", "Fable 7d" → "Fable 7-day used". Test it.
- **Account rows**, height 72, hairline on top, `liveRow` background when live:
  - Account cell: email (14 semibold, one line), then the second line exactly as today: plan `Chip`, "Not saved" chip, stale text, badges with their tooltips.
  - Window cell: one line with `cell.percentText` (15 semibold, monospaced digits, band colour) on the left and `cell.resetText` (11.5, `ter`) on the right; 7 pt below, a 4 pt capsule bar: `track` behind, `meterBar(cell.band)` filled to `cell.fill`. A missing window keeps today's strings ("—" with "none" or "—").
  - Action cell, right-aligned, 8 pt gap. Precedence is the same as today:
    1. `row.activity` → `ActivityPill`.
    2. Armed for removal → the "Remove" pill and the cancel button, with the 4-second auto-disarm.
    3. Live → the Live pill (unchanged tokens; height 28 to match Switch).
    4. Otherwise → **Switch**: filled `action`, white text, height 28, radius 7, 12.5 semibold, disabled per `row.switchDisabledReason`, same help text.
    
    Then, unless armed, a 28×28 "•••" `Menu` (accessibility label "More actions for \(row.email)"):
    - "Refresh" → `commands.refresh(row.id)`, disabled when `!row.refreshEnabled`.
    - "Remove Saved Login…" → arms the row (the existing two-step removal), disabled when `!row.removeEnabled`.
    
    While `row.isFetching`, show the spinning `arrow.clockwise` (reuse `RefreshButton`'s rotation) in place of the ellipsis glyph, so a refresh still gives feedback.
- **Footer hint row**, always present, height 42, hairline on top, 12.5 `ter`: `ManagerText.emptyHint(selected.tool)`. Remove the large empty state and `ManagerText.emptyTitle` if unused.

### "Show this context in" card

Reference: the `<section aria-label="Display">` in `Manager.dc.html`.

- Section label "Show this context in" (12 semibold, `ter`), 10 pt above a card (`tableCard`, radius 12, hairline border).
- Three equal cells in one row, height 48, hairline between cells, each a label (13 medium) and a small switch:
  - "Menu bar" → `preferences.isShown` / `setShown`.
  - "5-hour in menu bar" → `showsFiveHour` / `setShowsFiveHour`, disabled while `!preferences.isShown(selected)`, same help text as today.
  - "Popover" → `isInPopover` / `setInPopover`.
- Keep the existing accessibility labels on the toggles.

### Toasts

Reference: the `role="status"` element in `Manager.dc.html`.

All three inline banners move into a stack overlaid on the detail area, bottom centre, 24 pt above the bottom edge, 8 pt apart, newest lowest. The table no longer shifts when one appears.

- Shape: height 36 minimum, horizontal padding 14, radius 10, 1 pt border `hair`, shadow (black 40%, radius 12, y 8), 12.5 medium text. The background must be opaque: `win` with `soft` over it. Maximum width 560; text wraps.
- **Save result** (`saveBanner[selected]`): success shows a `checkmark` in `flashText` before the text and dismisses itself after 4 seconds. A refusal uses `warnText` for the text and stays until the next save in that context or a context change.
- **Notice** (`commands.notice`): same content as today, including the "Restart app-server" button when `commands.offersRestart` and the dismiss button. Lifetime unchanged.
- **Undo** (`commands.undoBanner`): text plus the Undo button. Lifetime unchanged (`closeUndo()` on selection change stays).
- Use `.accessibilityAddTraits(.updatesFrequently)` or post an announcement so VoiceOver still hears a save result.

## Toolbar

- Remove the interval picker, the Launch at login toggle and the Updates menu from `toolbar(_:)`.
- Keep the refresh button (`commands.refreshLive()`, help "Refresh live accounts").
- Add a Settings button after it: `gearshape`, help and accessibility label "Settings", opening the Settings window.
- Keep `navigationSubtitle` as is (`commands.hint` or "Live updated …").

## Settings window

Reference: `Settings.dc.html`.

- A second window controller in `Sources/Argus`, built in `AppDelegate` beside `ManagerWindowController` and handed the same `state`, `commands`, `loginItem` and `updater`. Title "Settings", titled and closable only, fixed content width 520, height fits content, centred, `isReleasedWhenClosed = false`.
- Add a "Settings…" item with ⌘, to the app menu in `makeMainMenu()`.
- Content padding 20 vertical, 24 horizontal; two cards 16 pt apart (`tableCard`, radius 12, hairline border, hairline between rows):
  - Card 1
    - "Refresh every" with the segmented picker (3, 5, 10 min), bound as today to `state.intervalMinutes` / `commands.setInterval`. Row height 52.
    - "Launch at login" with a switch, bound as today and disabled while `loginItem.isChanging`. Under the label, 11.5 `ter`: "Argus needs to be in your Applications folder." When `loginItem.message != nil`, show that message there instead, in `deadText`. Row height 56, growing with the message.
  - Card 2
    - "Argus" and "Version \(CFBundleShortVersionString)" (12.5, `ter`), with a "Check for Updates…" button → `updater.checkForUpdates()`. Row height 52.
    - "Check for updates automatically" with a switch bound to `updater.automaticallyChecks`. Row height 48.
- Remove the `loginItem.message` strip from `ManagerView`.

## Add context sheet

Reference: `AddContext.dc.html`.

- Presented as a sheet on the manager window from a sidebar "+" button. State: which tool it is for, plus the existing `newContextName`, `newContextPath`, `contextError`, `addingContext`.
- Width 460, padding 24, 18 pt between blocks:
  - Title: "Add a \(displayName) context" (15 semibold).
  - Body (12.5, `sub`): "A context is a folder \(displayName) runs from, chosen by \(variable). Each one keeps its own saved accounts." `variable` is `CODEX_HOME` for Codex, else `CLAUDE_CONFIG_DIR`.
  - "Folder" field, monospaced 12, placeholder `~/.claude-work` or `~/.codex-work`, with "Choose…" beside it (the existing `NSOpenPanel`: directories only, hidden files shown). Focused when the sheet opens.
  - "Name" field with a secondary "optional" in its label, placeholder "Defaults to the folder name". Check that placeholder against what `commands.addContext` does with an empty name; if it does something else, say that instead.
  - `contextError`, when set, under the fields in 12 `warnText`.
  - Buttons, right-aligned: "Cancel" (Escape) and "Add context" (Return, filled `action`, white text). "Add context" is disabled while the folder is empty or an add is running, when it reads "Adding…".
- On success: clear the fields, close the sheet, select the new context. On failure: stay open and show the error.
- Opening the sheet clears any previous error. The `onChange(of: selected)` reset of these fields can go once the inline row is gone.

## Tests

Add or update in `Tests/ArgusCoreTests`, Swift Testing, raw-identifier names, inside `TestSandbox` where a sandbox is needed:

- `ManagerSidebarRow` tightest-window cases listed above.
- `ManagerText.columnTitle`.
- `ManagerText.contextWarning`, one case per branch of `contextStatus` plus the two `nil` cases.
- Existing `ManagerLayout` tests stay green; add a case if `Columns` logic moves into `ManagerLayout` to make it testable.
- If an existing `REQ/F0x-AC-x` test covers the toolbar controls, the contexts card or the sidebar percentages, update it with the matching doc row rather than deleting it.

## Docs and change records

- `docs/design/magpie-lite/tech-design.md`: update the manager window rows under `## Behaviors` (sidebar values, toolbar controls, contexts list and add row, banners, row actions) and add a `## Changelog` line dated the day of the change. Mirror the AC rows in `features.md`. Point the manager UI reference at `ui/manager-redesign/`.
- `CHANGELOG.md`, under `[Unreleased]` → Changed, in the same commit. Suggested entries:
  - Manager window: contexts are grouped under their tool in the sidebar, each showing its tightest limit and which window it is.
  - Manager window: the accounts table has one meter per window; Refresh and Remove moved into a per-account menu.
  - Refresh interval, Launch at login and update options moved to a new Settings window (⌘,).
  - Adding a context is now a sheet opened from "+" in the sidebar; removing one is in that context's page menu.
  - Save results and notices appear as toasts instead of banners.

## Acceptance checklist

- [ ] Popover and menu bar item are pixel-identical to before, light and dark.
- [ ] No existing `Theme` token changed value.
- [ ] Every command reachable before is reachable now: save, switch, per-account refresh, remove with two-step confirm, undo, restart app-server, dismiss notice, add context, remove context, the three display toggles, interval, launch at login, check for updates, automatic checks.
- [ ] Shared-login and "must be exactly this path" warnings still appear, now on the context's page.
- [ ] Manager works at the 1000×560 minimum with three window columns, in light and dark.
- [ ] White-on-fill buttons use `action`, not `ok`.
- [ ] `make check` passes.
