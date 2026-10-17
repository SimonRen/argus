import AppKit
import MagpieLiteCore
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
        window.title = "Magpie Lite"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        window.contentView = NSHostingView(rootView: makeView())
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Providers sidebar plus the selected tool's accounts (ui/Manager.dc.html).
struct ManagerView: View {
    let state: AppState
    let commands: AccountCommands
    let preferences: MenuBarPreferences
    let loginItem: LoginItemController

    @State private var selected: Tool = .claude
    @State private var saveBanner: [Tool: String] = [:]
    @State private var tableWidth: CGFloat = 780
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = Theme(scheme)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                titlebar(t)
                t.hair.frame(height: 1)
                HStack(spacing: 0) {
                    sidebar(t).frame(width: 250)
                    t.hair.frame(width: 1)
                    detail(t, now: context.date)
                }
                t.hair.frame(height: 1)
                HStack(alignment: .top, spacing: 24) {
                    Text(ManagerText.footerHint)
                    Spacer()
                    Text("Saved logins: owner-only files in Application Support, kept out of Time Machine.")
                }
                .font(.system(size: 11.5)).foregroundStyle(t.sub).padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .foregroundStyle(t.text)
        .background(t.win)
        .onChange(of: selected) { commands.closeUndo() }
    }

    // MARK: Titlebar

    private func titlebar(_ t: Theme) -> some View {
        HStack(spacing: 18) {
            Text("Magpie Lite").font(.system(size: 14, weight: .semibold)).padding(.leading, 78)
            Spacer()
            HStack(spacing: 8) {
                Text("Refresh every").font(.system(size: 12)).foregroundStyle(t.sub).fixedSize()
                Picker("Refresh interval", selection: Binding(get: { state.intervalMinutes }, set: { commands.setInterval($0) })) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            if let hint = commands.hint {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(t.warnText).lineLimit(1).transition(.opacity)
            }
            RefreshButton(action: { await commands.refreshLive() }) { angle in
                Label { Text("Refresh live accounts") } icon: { Image(systemName: "arrow.clockwise").rotationEffect(angle) }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 28).background(t.btn, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Launch at login").font(.system(size: 12)).foregroundStyle(t.sub)
                    Toggle("Launch at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                if let message = loginItem.message {
                    Text(message).font(.system(size: 10.5)).foregroundStyle(t.deadText).lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 18).frame(height: 52).background(t.titlebar)
    }

    // MARK: Sidebar

    private func sidebar(_ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROVIDERS").font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(t.ter).padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(Tool.allCases, id: \.self) { tool in
                let row = ManagerSidebarRow.build(state.snapshot(tool), isShown: preferences.isShown(tool))
                Button { selected = tool } label: {
                    HStack(spacing: 10) {
                        ToolMark(tool: tool, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(tool.displayName).font(.system(size: 13, weight: selected == tool ? .semibold : .medium))
                                if row.showsMenubarGlyph {
                                    Image(systemName: "chart.bar.fill").font(.system(size: 9)).foregroundStyle(t.ter).accessibilityLabel("Shown in menubar")
                                }
                            }
                            Text(row.liveEmail ?? "Not signed in").font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(row.fiveHour.text).foregroundStyle(row.fiveHour.severity == .low ? t.barLow : t.text)
                            Text(row.sevenDay.text).foregroundStyle(row.sevenDay.severity == .low ? t.barLow : t.text)
                        }
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(selected == tool ? t.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
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
        let snapshot = state.snapshot(selected)
        let card = ToolCard.build(snapshot, expanded: true, dismissedUnsavedKey: nil, now: now)
        let rows = ([card.liveRow].compactMap { $0 } + card.others)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ToolMark(tool: selected, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.displayName).font(.system(size: 18, weight: .bold))
                        Text(ManagerText.header(snapshot)).font(.system(size: 12)).foregroundStyle(t.sub)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Text("Show in menubar").font(.system(size: 12))
                        Toggle("Show \(selected.displayName) in menubar",
                               isOn: Binding(get: { preferences.isShown(selected) }, set: { preferences.setShown(selected, $0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(.leading, 12).padding(.trailing, 6).frame(height: 30).background(t.soft, in: RoundedRectangle(cornerRadius: 9))
                    Button {
                        let tool = selected
                        Task {
                            let result = await commands.save(tool)
                            commands.dismissNotice()
                            saveBanner[tool] = ManagerText.saveBanner(result)
                        }
                    } label: {
                        Text("Save current login").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 30).background(t.ok, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
                if let banner = saveBanner[selected] {
                    Text(banner).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.flashText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(t.flashBg, in: RoundedRectangle(cornerRadius: 9))
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
                table(t, rows: rows)
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
    }

    private func table(_ t: Theme, rows: [AccountRow]) -> some View {
        let columns = Columns(width: tableWidth)
        return VStack(spacing: 0) {
            HStack(spacing: Columns.gap) {
                Text("ACCOUNT").frame(width: columns.account, alignment: .leading)
                Text("5 H WINDOW").frame(width: columns.window, alignment: .leading)
                Text("7 D WINDOW").frame(width: columns.window, alignment: .leading)
                Color.clear.frame(width: Columns.actions, height: 1)
            }
            .font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(t.ter)
            .padding(.horizontal, 16).padding(.vertical, 8).background(t.thead)
            ForEach(rows) { ManagerRowView(row: $0, tool: selected, theme: t, columns: columns, commands: commands) }
            if !rows.contains(where: \.isSaved) {
                VStack(spacing: 6) {
                    Text(ManagerText.emptyTitle).font(.system(size: 14, weight: .semibold))
                    Text(ManagerText.emptyHint(selected)).font(.system(size: 12)).foregroundStyle(t.sub).multilineTextAlignment(.center).frame(maxWidth: 360)
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
    let tool: Tool
    let theme: Theme
    let columns: Columns
    let commands: AccountCommands

    var body: some View {
        let t = theme
        HStack(alignment: .center, spacing: Columns.gap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.email).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    if let plan = row.plan, !plan.isEmpty { Chip(text: plan, theme: t) }
                    if !row.isSaved { Chip(text: "Not saved", theme: t) }
                    ForEach(Array(row.badges.enumerated()), id: \.offset) { item in
                        if case .stale(let age) = item.element {
                            Text("updated \(age)").font(.system(size: 11)).foregroundStyle(t.ter).fixedSize()
                        } else {
                            BadgeView(badge: item.element, theme: t)
                        }
                    }
                }
            }
            .frame(width: columns.account, alignment: .leading)
            column(row.groups.map { ($0.name, $0.fiveHour) }, t)
            column(row.groups.map { ($0.name, $0.sevenDay) }, t)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if row.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(t.liveText).frame(width: 6, height: 6)
                        Text("Live").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(t.liveText).padding(.horizontal, 9).frame(height: 24).background(t.liveBg, in: Capsule())
                } else {
                    PillButton(title: "Switch", fill: t.chip, foreground: t.text, disabled: row.switchDisabledReason != nil) {
                        Task { await commands.switchTo(row.id) }
                    }
                    .help(row.switchDisabledReason ?? "Switch \(tool.displayName) to \(row.email)")
                }
                RefreshButton(action: { await commands.refresh(row.id) }, active: row.isFetching) { angle in
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).rotationEffect(angle).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).foregroundStyle(t.sub).disabled(!row.refreshEnabled).opacity(row.refreshEnabled ? 1 : 0.35).help("Refresh this account")
                .accessibilityLabel("Refresh \(tool.displayName) \(row.email)")
                iconButton("trash", help: "Remove this saved login", enabled: row.isSaved, t) { Task { await commands.remove(row.id) } }
                    .accessibilityLabel("Remove \(row.email)")
            }
            .frame(width: Columns.actions)
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
