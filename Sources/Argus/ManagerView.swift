import AppKit
import ArgusCore
import SwiftUI

/// The manager window: regular activation policy (Dock, app menu) while open, back to accessory on close.
@MainActor final class ManagerWindowController: NSObject, NSWindowDelegate {
    private let makeView: () -> AnyView
    private let onClose: () -> Void
    private var window: NSWindow?

    init(makeView: @escaping () -> AnyView, onClose: @escaping () -> Void) {
        self.makeView = makeView
        self.onClose = onClose
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Argus"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        // SwiftUI's title and toolbar become the window's own: one native row beside the traffic lights.
        let host = NSHostingController(rootView: makeView())
        host.sceneBridgingOptions = [.title, .toolbars]
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Providers sidebar, one row per tool context, plus the selected context's accounts (ui/Manager.dc.html).
struct ManagerView: View {
    let state: AppState
    let commands: AccountCommands
    let preferences: MenuBarPreferences
    let loginItem: LoginItemController

    @State private var selected = ToolContext.default(.claude)
    @State private var saveBanner: [ToolContext: (text: String, problem: Bool)] = [:]
    @State private var tableWidth: CGFloat = 780
    /// The add-context row's fields and its last refusal.
    @State private var newContextName = ""
    @State private var newContextPath = ""
    @State private var contextError: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = Theme(scheme)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                if let message = loginItem.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(t.deadText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8).background(t.deadBg)
                }
                HStack(spacing: 0) {
                    sidebar(t).frame(width: 250)
                    t.hair.frame(width: 1)
                    detail(t, now: context.date)
                }
            }
            // The interval is the pop-up beside it, so the subtitle carries only the age.
            .navigationSubtitle(commands.hint ?? state.liveUpdatedAt.map { "Live updated \(PopoverText.age(since: $0, now: context.date))" } ?? "Not updated yet")
        }
        .navigationTitle("Argus")
        .toolbar { toolbar(t) }
        .foregroundStyle(t.text)
        .background(t.win)
        .onChange(of: selected) {
            commands.closeUndo()
            newContextName = ""
            newContextPath = ""
            contextError = nil
        }
    }

    // MARK: Toolbar

    /// Interval, refresh and launch at login, compact and always visible, in the window's own title row.
    @ToolbarContentBuilder
    private func toolbar(_ t: Theme) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                Text("Refresh every").font(.system(size: 12)).foregroundStyle(t.sub)
                Picker("Refresh interval", selection: Binding(get: { state.intervalMinutes }, set: { commands.setInterval($0) })) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.leading, 8).fixedSize().help("How often allowances are polled")
        }
        ToolbarItem(placement: .primaryAction) {
            RefreshButton(action: { await commands.refreshLive() }) { angle in
                Image(systemName: "arrow.clockwise").rotationEffect(angle)
            }
            .help("Refresh live accounts").accessibilityLabel("Refresh live accounts")
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                Text("Launch at login").font(.system(size: 12)).foregroundStyle(t.sub)
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            .padding(.horizontal, 6).fixedSize()
        }
    }

    // MARK: Sidebar

    private func sidebar(_ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROVIDERS").font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(t.ter).padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(Tool.allCases.flatMap(state.contexts), id: \.self) { context in
                let snapshot = state.snapshot(context)
                let row = ManagerSidebarRow.build(snapshot, isShown: preferences.isShown(context))
                Button { selected = context } label: {
                    HStack(spacing: 10) {
                        ToolMark(tool: context.tool, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(context.tool.displayName).font(.system(size: 13, weight: selected == context ? .semibold : .medium))
                                if row.showsMenubarGlyph {
                                    Image(systemName: "chart.bar.fill").font(.system(size: 9)).foregroundStyle(t.ter).accessibilityLabel("Shown in menubar")
                                }
                            }
                            // The context beside the email: beside the name it wraps "Claude Code" in the 250 pt sidebar.
                            HStack(spacing: 5) {
                                if let name = snapshot.contextName { ContextChip(context: context, name: name, theme: t) }
                                Text(row.liveEmail ?? "Not signed in").font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(row.fiveHour.text).foregroundStyle(row.fiveHour.severity == .low ? t.barLow : t.text)
                            Text(row.sevenDay.text).foregroundStyle(row.sevenDay.severity == .low ? t.barLow : t.text)
                        }
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(selected == context ? t.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 14).frame(maxHeight: .infinity).background(t.side)
    }

    // MARK: Detail

    private func detail(_ t: Theme, now: Date) -> some View {
        let snapshot = state.snapshot(selected), tool = selected.tool
        let card = ToolCard.build(snapshot, expanded: true, dismissedUnsavedKey: nil, now: now)
        let rows = card.rows
        return GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ToolMark(tool: tool, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(tool.displayName).font(.system(size: 18, weight: .bold))
                                if let name = card.contextName { ContextChip(context: selected, name: name, theme: t) }
                            }
                            Text(ManagerText.header(snapshot)).font(.system(size: 12)).foregroundStyle(t.sub)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Text("Show in").font(.system(size: 12)).foregroundStyle(t.sub).fixedSize()
                            Text("Menubar").font(.system(size: 12)).fixedSize()
                            Toggle("Show \(tool.displayName) in menubar",
                                   isOn: Binding(get: { preferences.isShown(selected) }, set: { preferences.setShown(selected, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            Text("Popover").font(.system(size: 12)).fixedSize().padding(.leading, 4)
                            Toggle("Show \(tool.displayName) in popover",
                                   isOn: Binding(get: { preferences.isInPopover(selected) }, set: { preferences.setInPopover(selected, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                        .padding(.leading, 12).padding(.trailing, 6).frame(height: 30).background(t.soft, in: RoundedRectangle(cornerRadius: 9))
                        Button {
                            let context = selected
                            Task {
                                let result = await commands.save(context)
                                commands.dismissNotice()
                                let problem = if case .refused = result { true } else { false }
                                saveBanner[context] = (ManagerText.saveBanner(result), problem)
                            }
                        } label: {
                            Text("Save current login").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 30).background(t.ok, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    if let banner = saveBanner[selected] {
                        Text(banner.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(banner.problem ? t.warnText : t.flashText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(banner.problem ? t.warnBg : t.flashBg, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if let notice = commands.notice {
                        HStack(alignment: .center, spacing: 10) {
                            Text(notice).font(.system(size: 12, weight: .semibold)).foregroundStyle(commands.noticeIsProblem ? t.warnText : t.flashText)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            if commands.offersRestart {
                                PillButton(title: "Restart app-server", fill: t.ok) { Task { await commands.restartCodexDaemon() } }
                            }
                            Button(action: commands.dismissNotice) {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                            }
                            .buttonStyle(HoverStyle()).foregroundStyle(t.sub).accessibilityLabel("Dismiss")
                        }
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 6))
                        .background(commands.noticeIsProblem ? t.warnBg : t.flashBg, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if let undo = commands.undoBanner {
                        HStack(spacing: 10) {
                            Text(undo).font(.system(size: 12))
                            Spacer()
                            Button { Task { await commands.undo() } } label: {
                                Text("Undo").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).frame(height: 26)
                                    .background(t.btn, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 6)).background(t.soft, in: RoundedRectangle(cornerRadius: 9))
                    }
                    table(t, rows: rows, availableWidth: proxy.size.width - 48)
                    if tool.supportsContexts { contexts(t) }
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func table(_ t: Theme, rows: [AccountRow], availableWidth: CGFloat) -> some View {
        let width = ManagerLayout.fittingTableWidth(measuredWidth: tableWidth, availableWidth: availableWidth)
        let columns = Columns(width: width)
        return VStack(spacing: 0) {
            HStack(spacing: Columns.gap) {
                Text("ACCOUNT").frame(width: columns.account, alignment: .leading)
                Text("5 H WINDOW").frame(width: columns.window, alignment: .leading)
                Text("7 D WINDOW").frame(width: columns.window, alignment: .leading)
                Color.clear.frame(width: Columns.actions, height: 1)
            }
            .font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(t.ter)
            .padding(.horizontal, 16).padding(.vertical, 8).background(t.thead)
            ForEach(rows) { ManagerRowView(row: $0, context: selected, theme: t, columns: columns, commands: commands) }
            if !rows.contains(where: \.isSaved) {
                VStack(spacing: 6) {
                    Text(ManagerText.emptyTitle).font(.system(size: 14, weight: .semibold))
                    Text(ManagerText.emptyHint(selected.tool)).font(.system(size: 12)).foregroundStyle(t.sub).multilineTextAlignment(.center).frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36).overlay(alignment: .top) { t.hair.frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity)
        .background(t.tableCard).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.hair, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
    }
}

extension ManagerView {
    /// The tool's contexts: each with its live login and Remove, then a row to add one. Each has its own page.
    private func contexts(_ t: Theme) -> some View {
        let tool = selected.tool
        let variable = tool == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONTEXTS").font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(t.ter)
                Spacer()
                Text("Folders \(tool.displayName) runs from, chosen by \(variable). Saved accounts are shared by all.")
                    .font(.system(size: 11)).foregroundStyle(t.ter).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(t.thead)
            ForEach(state.contexts(tool), id: \.self) { context in
                HStack(spacing: Columns.gap) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.name).font(.system(size: 13, weight: .medium))
                        Text(context.assignment ?? "\(variable) unset").font(.system(size: 11, design: .monospaced)).foregroundStyle(t.sub)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    let shared = state.sharesLogin(context)
                    Text(ManagerText.contextStatus(state.liveState(context), context: context, sharedWith: shared))
                        .font(.system(size: 12)).foregroundStyle(shared == nil ? t.sub : t.warnText).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Button {
                            Task {
                                contextError = await commands.removeContext(context)
                                if contextError == nil, selected == context { selected = .default(tool) }
                            }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain).foregroundStyle(t.sub).disabled(context.isDefault).opacity(context.isDefault ? 0 : 1)
                        .help("Forget this context; its folder and logins stay").accessibilityLabel("Remove context \(context.name)")
                    }
                    .frame(width: Columns.actions)
                }
                .padding(.horizontal, Columns.inset).padding(.vertical, 10)
                .overlay(alignment: .top) { t.hair.frame(height: 1) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Name (optional)", text: $newContextName).textFieldStyle(.roundedBorder).frame(width: 150)
                    TextField("\(variable), e.g. ~/.\(tool == .codex ? "codex" : "claude")-work", text: $newContextPath)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.showsHiddenFiles = true
                        if panel.runModal() == .OK, let url = panel.url { newContextPath = url.path }
                    }
                    PillButton(title: "Add", fill: t.ok, disabled: newContextPath.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task {
                            contextError = await commands.addContext(tool, path: newContextPath, name: newContextName)
                            if contextError == nil { newContextName = ""; newContextPath = "" }
                        }
                    }
                }
                if let contextError {
                    Text(contextError).font(.system(size: 12)).foregroundStyle(t.warnText)
                }
            }
            .padding(.horizontal, Columns.inset).padding(.vertical, 10)
            .overlay(alignment: .top) { t.hair.frame(height: 1) }
        }
        .frame(maxWidth: .infinity)
        .background(t.tableCard).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.hair, lineWidth: 1))
    }
}

/// Table columns in the design's 1.25 : 1 : 1 ratio beside a 140 pt action column.
private struct Columns {
    static let gap: CGFloat = 20, actions: CGFloat = 140, inset: CGFloat = 16
    let account: CGFloat, window: CGFloat

    init(width: CGFloat) {
        let flexible = max(300, width - 2 * Self.inset - Self.actions - 3 * Self.gap)
        account = flexible * 1.25 / 3.25
        window = flexible / 3.25
    }
}

private struct ManagerRowView: View {
    let row: AccountRow
    /// The page's context: what Switch writes.
    let context: ToolContext
    let theme: Theme
    let columns: Columns
    let commands: AccountCommands
    /// Remove takes two clicks: the first arms it for a few seconds, the second deletes.
    @State private var armed = false

    private var tool: Tool { context.tool }

    var body: some View {
        let t = theme
        HStack(alignment: .center, spacing: Columns.gap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.email).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    if let plan = row.plan, !plan.isEmpty { Chip(text: plan, theme: t) }
                    if !row.isSaved { Chip(text: "Not saved", theme: t) }
                    let problem = PopoverText.problem(tool: tool, error: row.error, retryAt: row.retryAt, now: .now, timeZone: .current)
                    ForEach(Array(row.badges.enumerated()), id: \.offset) { item in
                        if case .stale(let age) = item.element {
                            Text("updated \(age)").font(.system(size: 11)).foregroundStyle(t.ter).fixedSize().help(problem)
                        } else {
                            BadgeView(badge: item.element, theme: t, help: item.element.isFetchProblem ? problem : nil)
                        }
                    }
                }
            }
            .frame(width: columns.account, alignment: .leading)
            column(row.groups.map { ($0.name, $0.fiveHour) }, t)
            column(row.groups.map { ($0.name, $0.sevenDay) }, t)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if armed {
                    PillButton(title: "Remove", fill: t.barLow) {
                        armed = false
                        Task { await commands.remove(row.id) }
                    }
                    .help("Click to delete this saved login").accessibilityLabel("Confirm removing \(row.email)")
                    iconButton("xmark", help: "Keep this saved login", enabled: true, t) { armed = false }
                        .accessibilityLabel("Cancel removing \(row.email)")
                } else if row.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(t.liveText).frame(width: 6, height: 6)
                        Text("Live").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(t.liveText).padding(.horizontal, 9).frame(height: 24).background(t.liveBg, in: Capsule())
                } else {
                    PillButton(title: "Switch", fill: t.chip, foreground: t.text, disabled: row.switchDisabledReason != nil) {
                        Task { await commands.switchTo(row.id, in: context) }
                    }
                    .help(row.switchDisabledReason ?? "Switch \(tool.displayName) to \(row.email)")
                }
                if !armed {
                    RefreshButton(action: { await commands.refresh(row.id) }, active: row.isFetching) { angle in
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).rotationEffect(angle).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(t.sub).disabled(!row.refreshEnabled).opacity(row.refreshEnabled ? 1 : 0.35).help("Refresh this account")
                    .accessibilityLabel("Refresh \(tool.displayName) \(row.email)")
                    iconButton("trash", help: "Remove this saved login", enabled: row.isSaved, t) { armed = true }
                        .accessibilityLabel("Remove \(row.email)")
                }
            }
            .frame(width: Columns.actions)
            .task(id: armed) {
                guard armed else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { armed = false }
            }
        }
        .padding(.horizontal, Columns.inset).padding(.vertical, 12)
        .background(row.isLive ? t.liveRow : .clear)
        .overlay(alignment: .top) { t.hair.frame(height: 1) }
    }

    private func column(_ cells: [(String?, WindowCell)], _ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { item in
                let (name, cell) = item.element
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let name { Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.sub).lineLimit(1) }
                        Text(cell.percentText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Spacer(minLength: 2)
                        Text(cell.resetText).font(.system(size: 11)).monospacedDigit().foregroundStyle(t.ter).lineLimit(1)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(t.track)
                            Capsule().fill(t.bar(cell.band)).frame(width: proxy.size.width * min(1, max(0, cell.fill)))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .frame(width: columns.window, alignment: .leading)
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, _ t: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain).foregroundStyle(t.sub).disabled(!enabled).opacity(enabled ? 1 : 0.35).help(help)
    }
}
