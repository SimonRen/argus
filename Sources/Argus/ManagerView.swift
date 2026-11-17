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
        // Wide enough that the detail header's title keeps the room it had before the 5h switch joined the Show in group.
        window.minSize = NSSize(width: 1000, height: 560)
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

/// Tools grouped in the sidebar, one row per context, plus the selected context's page (ui/manager-redesign/Manager.dc.html).
struct ManagerView: View {
    let state: AppState
    let commands: AccountCommands
    let preferences: MenuBarPreferences
    let openSettings: () -> Void

    @State private var selected = ToolContext.default(.claude)
    /// A save's result, or a context removal's refusal, as a toast; `id` lets a success dismiss only itself.
    @State private var toast: [ToolContext: (text: String, problem: Bool, id: UUID)] = [:]
    @State private var tableWidth: CGFloat = 780
    /// The tool the Add context sheet is open for.
    @State private var addingFor: Tool?
    /// A context's Remove under way: its menu waits meanwhile.
    @State private var removingContext: ToolContext?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = Theme(scheme)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 0) {
                sidebar(t).frame(width: 250)
                t.hair.frame(width: 1)
                detail(t, now: context.date)
                    .overlay(alignment: .bottom) { toasts(t) }
            }
            .navigationSubtitle(commands.hint ?? state.liveUpdatedAt.map { "Live updated \(PopoverText.age(since: $0, now: context.date))" } ?? "Not updated yet")
        }
        .navigationTitle("Argus")
        .toolbar { toolbar(t) }
        .foregroundStyle(t.text)
        .background(t.win)
        .sheet(isPresented: Binding(get: { addingFor != nil }, set: { if !$0 { addingFor = nil } })) {
            if let tool = addingFor {
                AddContextSheet(tool: tool, state: state, commands: commands) { added in
                    addingFor = nil
                    if let added { selected = added }
                }
                .environment(\.colorScheme, scheme)
            }
        }
        .onChange(of: selected) {
            commands.closeUndo()
            toast = [:]
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ t: Theme) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            RefreshButton(action: { await commands.refreshLive() }) { angle in
                Image(systemName: "arrow.clockwise").rotationEffect(angle)
            }
            .help("Refresh live accounts").accessibilityLabel("Refresh live accounts")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help("Settings").accessibilityLabel("Settings")
        }
    }

    // MARK: Sidebar

    private func sidebar(_ t: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            ToolMark(tool: tool, size: 18)
                            Text(tool.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.sub)
                            Spacer(minLength: 0)
                            if tool.supportsContexts {
                                Button { addingFor = tool } label: {
                                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                                }
                                .buttonStyle(HoverStyle()).foregroundStyle(t.sub)
                                .help("Add a \(tool.displayName) context").accessibilityLabel("Add a \(tool.displayName) context")
                            }
                        }
                        .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
                        ForEach(state.contexts(tool), id: \.self) { sidebarRow($0, t) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity).background(t.side)
    }

    private func sidebarRow(_ context: ToolContext, _ t: Theme) -> some View {
        let row = ManagerSidebarRow.build(state.snapshot(context))
        let isSelected = selected == context
        return Button { selected = context } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.name).font(.system(size: 13, weight: isSelected ? .semibold : .medium)).lineLimit(1)
                    Text(row.liveEmail ?? "Not signed in").font(.system(size: 11.5)).foregroundStyle(t.sub).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(row.tightest?.percentText ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(t.meterText(row.tightest?.band ?? .empty))
                    if let label = row.tightest?.label { Text(label).font(.system(size: 10.5)).foregroundStyle(t.ter).lineLimit(1) }
                }
            }
            .padding(.horizontal, 10).frame(height: 48)
            .background(isSelected ? t.soft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(context.tool.displayName) \(context.name)")
    }

    // MARK: Detail

    private func detail(_ t: Theme, now: Date) -> some View {
        let snapshot = state.snapshot(selected)
        let card = ToolCard.build(snapshot, expanded: true, dismissedUnsavedKey: nil, pending: commands.pending[selected], now: now)
        return GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header(t, snapshot: snapshot, card: card)
                    table(t, card: card, availableWidth: proxy.size.width - 48)
                    display(t)
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
                // Room for the toasts under the last card.
                .padding(.bottom, 48)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ t: Theme, snapshot: ToolSnapshot, card: ToolCard) -> some View {
        let tool = selected.tool
        let unsaved = ManagerText.isUnsaved(snapshot)
        let warning = ManagerText.contextWarning(state.liveState(selected), context: selected, sharedWith: state.sharesLogin(selected))
        return HStack(alignment: .center, spacing: 12) {
            ToolMark(tool: tool, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(tool.displayName).font(.system(size: 18, weight: .bold))
                    if let name = card.contextName { ContextChip(context: selected, name: name, theme: t) }
                }
                HStack(spacing: 6) {
                    Text(ManagerText.header(snapshot)).font(.system(size: 12)).foregroundStyle(t.sub).lineLimit(1)
                    if tool.supportsContexts {
                        Text("·").font(.system(size: 12)).foregroundStyle(t.ter)
                        Text(selected.assignment ?? "\(tool.contextVariable) unset").font(.system(size: 11, design: .monospaced)).foregroundStyle(t.ter)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                if let warning {
                    Text(warning).font(.system(size: 12)).foregroundStyle(t.warnText).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if !selected.isDefault { contextMenu(t) }
            Button {
                let context = selected
                Task {
                    let result = await commands.save(context)
                    commands.dismissNotice()
                    let problem = if case .refused = result { true } else { false }
                    show(ManagerText.saveBanner(result), problem: problem, in: context)
                }
            } label: {
                Text(card.pending == .saving ? PendingAction.saving.text : "Save current login").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(unsaved ? .white : t.text)
                    .padding(.horizontal, 12).frame(height: 30).background(unsaved ? t.action : t.btn, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(HoverStyle(filled: AnyShape(RoundedRectangle(cornerRadius: 9))))
            .disabled(card.pending != nil).opacity(card.pending != nil ? 0.6 : 1)
        }
    }

    /// An added context's page menu: Remove Context, which forgets it and leaves its folder and logins alone.
    private func contextMenu(_ t: Theme) -> some View {
        Menu {
            Button("Remove Context…") {
                let context = selected
                removingContext = context
                Task {
                    let error = await commands.removeContext(context)
                    removingContext = nil
                    if let error {
                        show(error, problem: true, in: context)
                    } else if selected == context {
                        selected = .default(context.tool)
                    }
                }
            }
        } label: {
            if removingContext == selected {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "ellipsis")
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 30, height: 30)
        .disabled(removingContext != nil)
        .help("Forget this context; its folder and logins stay").accessibilityLabel("More actions for \(selected.name)")
    }

    private func table(_ t: Theme, card: ToolCard, availableWidth: CGFloat) -> some View {
        let width = ManagerLayout.fittingTableWidth(measuredWidth: tableWidth, availableWidth: availableWidth)
        let columns = Columns(width: width, windows: card.columns.count)
        return VStack(spacing: 0) {
            HStack(spacing: Columns.gap) {
                Text("Account").frame(width: columns.account, alignment: .leading)
                ForEach(card.columns, id: \.self) { label in
                    Text(ManagerText.columnTitle(label)).lineLimit(1).frame(width: columns.window, alignment: .leading)
                }
                Color.clear.frame(width: Columns.actions, height: 1)
            }
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(t.ter)
            .padding(.horizontal, Columns.inset).frame(height: 36).frame(maxWidth: .infinity, alignment: .leading).background(t.thead)
            ForEach(card.rows) { row in
                ManagerRowView(row: row, cells: row.cells(card.columns), context: selected, theme: t, columns: columns, commands: commands)
            }
            Text(ManagerText.emptyHint(selected.tool)).font(.system(size: 12.5)).foregroundStyle(t.ter)
                .padding(.horizontal, Columns.inset).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .overlay(alignment: .top) { t.hair.frame(height: 1) }
        }
        .frame(maxWidth: .infinity)
        .background(t.tableCard).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.hair, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
    }

    /// Where this context shows: the menubar (and its 5 h there) and the popover.
    private func display(_ t: Theme) -> some View {
        let name = selected.tool.displayName
        return VStack(alignment: .leading, spacing: 10) {
            Text("Show this context in").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.ter)
            HStack(spacing: 0) {
                displayCell("Menu bar", t) {
                    Toggle("Show \(name) in menubar", isOn: Binding(get: { preferences.isShown(selected) }, set: { preferences.setShown(selected, $0) }))
                }
                t.hair.frame(width: 1)
                displayCell("5-hour in menu bar", t) {
                    Toggle("Show \(name) 5h in menubar",
                           isOn: Binding(get: { preferences.showsFiveHour(selected) }, set: { preferences.setShowsFiveHour(selected, $0) }))
                        .disabled(!preferences.isShown(selected))
                        .help("Show the 5-hour use above the 7-day use in the menubar")
                }
                t.hair.frame(width: 1)
                displayCell("Popover", t) {
                    Toggle("Show \(name) in popover", isOn: Binding(get: { preferences.isInPopover(selected) }, set: { preferences.setInPopover(selected, $0) }))
                }
            }
            .frame(height: 48)
            .background(t.tableCard).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.hair, lineWidth: 1))
        }
    }

    private func displayCell(_ label: String, _ t: Theme, @ViewBuilder toggle: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            toggle().toggleStyle(.switch).labelsHidden().controlSize(.small).tint(t.action)
        }
        .padding(.leading, 20).padding(.trailing, 16).frame(maxWidth: .infinity)
    }

    // MARK: Toasts

    private func show(_ text: String, problem: Bool, in context: ToolContext) {
        let id = UUID()
        toast[context] = (text, problem, id)
        AccessibilityNotification.Announcement(text).post()
        guard !problem else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast[context]?.id == id { toast[context] = nil }
        }
    }

    /// Save results, notices and Undo, over the bottom of the page so the table never shifts.
    private func toasts(_ t: Theme) -> some View {
        VStack(spacing: 8) {
            if let toast = toast[selected] {
                Toast(theme: t) {
                    if !toast.problem { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(t.flashText) }
                    Text(toast.text).foregroundStyle(toast.problem ? t.warnText : t.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let notice = commands.notice {
                Toast(theme: t) {
                    Text(notice).foregroundStyle(commands.noticeIsProblem ? t.warnText : t.text).fixedSize(horizontal: false, vertical: true)
                    if commands.offersRestart {
                        PillButton(title: "Restart app-server", fill: t.action) { Task { await commands.restartCodexDaemon() } }
                    }
                    Button(action: commands.dismissNotice) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(HoverStyle()).foregroundStyle(t.sub).accessibilityLabel("Dismiss")
                }
            }
            if let undo = commands.undoBanner {
                Toast(theme: t) {
                    Text(undo).fixedSize(horizontal: false, vertical: true)
                    Button { Task { await commands.undo() } } label: {
                        Text("Undo").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 24)
                            .background(t.btn, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(HoverStyle(filled: AnyShape(RoundedRectangle(cornerRadius: 7))))
                }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
    }
}

private struct Toast<Content: View>: View {
    let theme: Theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        HStack(spacing: 10) { content() }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 36)
            .background(theme.soft, in: shape).background(theme.win, in: shape)
            .overlay(shape.stroke(theme.hair, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
            .frame(maxWidth: 560)
            .accessibilityElement(children: .contain)
    }
}

/// Table columns: the account at 1.3 beside one per window at 1, then a fixed action column.
private struct Columns {
    static let gap: CGFloat = 28, actions: CGFloat = 132, inset: CGFloat = 20
    let account: CGFloat, window: CGFloat

    init(width: CGFloat, windows: Int) {
        let flexible = max(240, width - 2 * Self.inset - Self.actions - CGFloat(windows + 1) * Self.gap)
        let unit = flexible / (1.3 + CGFloat(windows))
        account = unit * 1.3
        window = unit
    }
}

private struct ManagerRowView: View {
    let row: AccountRow
    let cells: [WindowCell]
    /// The page's context: what Switch writes.
    let context: ToolContext
    let theme: Theme
    let columns: Columns
    let commands: AccountCommands
    /// Remove takes two clicks: the menu's Remove arms it for a few seconds, the red Remove deletes.
    @State private var armed = false

    private var tool: Tool { context.tool }

    var body: some View {
        let t = theme
        HStack(alignment: .center, spacing: Columns.gap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.email).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
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
            ForEach(Array(cells.enumerated()), id: \.offset) { meter($0.element, t) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions(t)
            }
            .frame(width: Columns.actions)
            .task(id: armed) {
                guard armed else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { armed = false }
            }
        }
        .padding(.horizontal, Columns.inset).frame(minHeight: 72)
        .background(row.isLive ? t.liveRow : .clear)
        .overlay(alignment: .top) { t.hair.frame(height: 1) }
    }

    @ViewBuilder private func actions(_ t: Theme) -> some View {
        if let activity = row.activity {
            ActivityPill(activity: activity, theme: t)
        } else if armed {
            PillButton(title: "Remove", fill: t.barLow) {
                armed = false
                Task { await commands.remove(row.id, in: context) }
            }
            .help("Click to delete this saved login").accessibilityLabel("Confirm removing \(row.email)")
            Button { armed = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).foregroundStyle(t.sub).help("Keep this saved login").accessibilityLabel("Cancel removing \(row.email)")
        } else if row.isLive {
            HStack(spacing: 5) {
                Circle().fill(t.liveText).frame(width: 6, height: 6)
                Text("Live").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(t.liveText).padding(.horizontal, 10).frame(height: 28).background(t.liveBg, in: Capsule())
        } else {
            let disabled = row.switchDisabledReason != nil
            Button { Task { await commands.switchTo(row.id, in: context) } } label: {
                Text("Switch").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28).background(t.action, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(HoverStyle(filled: AnyShape(RoundedRectangle(cornerRadius: 7)))).disabled(disabled).opacity(disabled ? 0.4 : 1)
            .help(row.switchDisabledReason ?? "Switch \(tool.displayName) to \(row.email)")
        }
        if !armed { more(t) }
    }

    /// Refresh and Remove; a refresh in flight spins in the menu's place.
    @ViewBuilder private func more(_ t: Theme) -> some View {
        if row.isFetching {
            // ponytail: the menu is out of reach for the moment a fetch takes; a spinning label inside the Menu doesn't animate.
            RefreshButton(action: {}, active: true) { angle in
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).rotationEffect(angle).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(t.sub).allowsHitTesting(false).accessibilityLabel("Refreshing \(row.email)")
        } else {
            Menu {
                Button("Refresh") { Task { await commands.refresh(row.id) } }.disabled(!row.refreshEnabled)
                Button("Remove Saved Login…") { armed = true }.disabled(!row.removeEnabled)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 28)
            .accessibilityLabel("More actions for \(row.email)")
        }
    }

    private func meter(_ cell: WindowCell, _ t: Theme) -> some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(cell.percentText).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(t.meterText(cell.band))
                Spacer(minLength: 2)
                Text(cell.resetText).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(t.ter).lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.track)
                    Capsule().fill(t.meterBar(cell.band)).frame(width: proxy.size.width * min(1, max(0, cell.fill)))
                }
            }
            .frame(height: 4)
        }
        .frame(width: columns.window, alignment: .leading)
    }
}

/// Adds a context for `tool`: its folder and an optional name (ui/manager-redesign/AddContext.dc.html).
private struct AddContextSheet: View {
    let tool: Tool
    let state: AppState
    let commands: AccountCommands
    /// The added context, or nil on Cancel.
    let onClose: (ToolContext?) -> Void

    @State private var path = ""
    @State private var name = ""
    @State private var error: String?
    @State private var adding = false
    @FocusState private var folderFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = Theme(scheme)
        let empty = path.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a \(tool.displayName) context").font(.system(size: 15, weight: .semibold))
                Text("A context is a folder \(tool.displayName) runs from, chosen by \(tool.contextVariable). Each one keeps its own saved accounts.")
                    .font(.system(size: 12.5)).foregroundStyle(t.sub).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Folder").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("~/.\(tool == .codex ? "codex" : "claude")-work", text: $path)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).focused($folderFocused)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.showsHiddenFiles = true
                        if panel.runModal() == .OK, let url = panel.url { path = url.path }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                (Text("Name ").font(.system(size: 12, weight: .semibold)) + Text("optional").font(.system(size: 12)).foregroundStyle(t.ter))
                TextField("Defaults to the folder name", text: $name).textFieldStyle(.roundedBorder)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(t.warnText).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onClose(nil) }.keyboardShortcut(.cancelAction)
                Button {
                    adding = true
                    Task {
                        error = await commands.addContext(tool, path: path, name: name)
                        adding = false
                        // The new context is the last one added.
                        if error == nil { onClose(state.addedContexts[tool]?.last) }
                    }
                } label: {
                    Text(adding ? "Adding…" : "Add context").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28).background(t.action, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(HoverStyle(filled: AnyShape(RoundedRectangle(cornerRadius: 7)))).keyboardShortcut(.defaultAction)
                .disabled(empty || adding).opacity(empty || adding ? 0.5 : 1)
            }
        }
        .padding(24).frame(width: 460)
        .foregroundStyle(t.text)
        .onAppear { folderFocused = true }
    }
}
