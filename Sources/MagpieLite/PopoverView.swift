import AppKit
import MagpieLiteCore
import SwiftUI

/// The visible height (menu bar and Dock excluded) of the screen the popover opens on; set just before it opens.
@MainActor @Observable final class PopoverScreen {
    var visibleHeight: CGFloat = 800
}

/// The popover: header, notices, one card per tool, footer (ui/Main.dc.html).
struct PopoverView: View {
    let state: AppState
    let commands: AccountCommands
    let screen: PopoverScreen
    let preferences: MenuBarPreferences
    let openManager: () -> Void

    /// Tools whose other accounts are listed; kept until the app quits.
    @State private var expanded: Set<Tool> = []
    @State private var cardsHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(Theme(scheme), now: context.date)
        }
        .frame(width: 392)
    }

    private func content(_ t: Theme, now: Date) -> some View {
        let cards = Tool.allCases.filter(preferences.isInPopover).map { tool in
            ToolCard.build(state.snapshot(tool).hidingMinorGroups, expanded: expanded.contains(tool), dismissedUnsavedKey: commands.dismissedUnsaved[tool], now: now)
        }
        // The whole popover fits the screen: what's left after the header, notices, footer and the arrow's margin.
        let maxCards = max(240, screen.visibleHeight - topHeight - footerHeight - 32)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                header(t, now: now)
                notices(t, cards: cards)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { topHeight = $0 }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(cards, id: \.tool) { CardView(card: $0, theme: t, actions: actions(for: $0.tool)) }
                    if cards.isEmpty {
                        Text("Every tool is hidden here. Turn on Show in popover in Manage accounts…")
                            .font(.system(size: 12)).foregroundStyle(t.sub).multilineTextAlignment(.center).padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 10)
                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .frame(height: min(max(cardsHeight, 1), maxCards))
            .onPreferenceChange(HeightKey.self) { cardsHeight = $0 }
            footer(t)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { footerHeight = $0 }
        }
        .foregroundStyle(t.text)
    }

    private func header(_ t: Theme, now: Date) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allowance").font(.system(size: 15, weight: .semibold))
                Text(commands.hint ?? PopoverText.subtitle(lastLiveFetch: state.lastLiveFetch, intervalMinutes: state.intervalMinutes, now: now))
                    .font(.system(size: 11.5)).foregroundStyle(commands.hint == nil ? t.sub : t.warnText)
                    .lineLimit(1).minimumScaleFactor(0.85).animation(.easeInOut(duration: 0.2), value: commands.hint)
            }
            Spacer()
            HStack(spacing: 6) {
                RefreshButton(action: { await commands.refreshLive() }) { angle in
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text).rotationEffect(angle)
                        .frame(width: 30, height: 30).background(t.btn, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).help("Refresh live accounts").accessibilityLabel("Refresh live accounts")
                SquareButton(symbol: "macwindow", help: "Open manager window", theme: t, action: openManager)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 14))
    }

    @ViewBuilder
    private func notices(_ t: Theme, cards: [ToolCard]) -> some View {
        if let notice = commands.notice {
            NoticeView(theme: t, icon: "checkmark", tint: t.liveText, background: t.notice, text: notice, onDismiss: commands.dismissNotice) {
                if commands.offersRestart {
                    PillButton(title: "Restart app-server", fill: t.ok) { Task { await commands.restartCodexDaemon() } }
                }
            }
        }
        ForEach(cards.filter { $0.unsavedBanner != nil }, id: \.tool) { card in
            NoticeView(theme: t, icon: "exclamationmark.triangle", tint: t.warnText, background: t.warnBg, text: card.unsavedBanner!, onDismiss: nil) {
                HStack(spacing: 6) {
                    PillButton(title: "Save login", fill: t.ok) { Task { await commands.save(card.tool) } }
                    PillButton(title: "Later", fill: t.btn, foreground: t.text) { commands.later(card.tool) }
                }
            }
        }
    }

    private func footer(_ t: Theme) -> some View {
        HStack {
            Button("Manage accounts…", action: openManager)
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.link)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(t.sub)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
    }

    private func actions(for tool: Tool) -> CardView.Actions {
        CardView.Actions(
            toggle: { if expanded.contains(tool) { expanded.remove(tool) } else { expanded.insert(tool) } },
            switchTo: { key in Task { await commands.switchTo(key) } },
            refresh: { key in await commands.refresh(key) })
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Card and rows

struct CardView: View {
    struct Actions {
        let toggle: () -> Void
        let switchTo: (AccountKey) -> Void
        let refresh: @MainActor (AccountKey) async -> Void
    }

    let card: ToolCard
    let theme: Theme
    let actions: Actions

    var body: some View {
        let t = theme
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ToolMark(tool: card.tool, size: 18)
                Text(card.tool.displayName).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let more = card.moreLabel {
                    Button(action: actions.toggle) {
                        HStack(spacing: 3) {
                            Text(more)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(more == "Show less" ? 180 : 0))
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(t.sub)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(more == "Show less" ? "Hide other \(card.tool.displayName) accounts" : "Show other \(card.tool.displayName) accounts")
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
            if let live = card.liveRow {
                RowView(row: live, tool: card.tool, suggestion: card.suggestion, theme: t, actions: actions)
            } else if let status = card.liveStatusText {
                HStack {
                    Text(status).font(.system(size: 12)).foregroundStyle(t.sub)
                    Spacer()
                }
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .overlay(alignment: .top) { t.hair.frame(height: 1) }
            }
            if card.moreLabel == "Show less" {
                ForEach(card.others) { RowView(row: $0, tool: card.tool, suggestion: nil, theme: t, actions: actions) }
            }
        }
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.hair, lineWidth: 1))
    }
}

struct RowView: View {
    let row: AccountRow
    let tool: Tool
    let suggestion: Suggestion?
    let theme: Theme
    let actions: CardView.Actions

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.email).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if let plan = row.plan, !plan.isEmpty { Chip(text: plan, theme: t) }
                Spacer(minLength: 4)
                let problem = PopoverText.problem(tool: tool, error: row.error, retryAt: row.retryAt, now: .now, timeZone: .current)
                ForEach(Array(row.badges.enumerated()), id: \.offset) {
                    BadgeView(badge: $0.element, theme: t, help: $0.element.isFetchProblem ? problem : nil)
                }
                if row.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(t.liveText).frame(width: 6, height: 6)
                        Text("Live").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(t.liveText).padding(.horizontal, 9).frame(height: 22).background(t.liveBg, in: Capsule())
                } else {
                    PillButton(title: "Switch", fill: t.btn, foreground: t.text, disabled: row.switchDisabledReason != nil) { actions.switchTo(row.id) }
                        .help(row.switchDisabledReason ?? "Switch \(tool.displayName) to \(row.email)")
                }
                RefreshButton(action: { await actions.refresh(row.id) }, active: row.isFetching) { angle in
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold)).rotationEffect(angle).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(t.sub).disabled(!row.refreshEnabled).opacity(row.refreshEnabled ? 1 : 0.4)
                .help("Refresh this account").accessibilityLabel("Refresh \(tool.displayName) \(row.email)")
            }
            .frame(height: 22)
            VStack(spacing: 6) {
                ForEach(Array(row.groups.enumerated()), id: \.offset) { GroupView(group: $0.element, theme: t) }
            }
            if let suggestion {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold))
                    Text(suggestion.text).font(.system(size: 11.5)).frame(maxWidth: .infinity, alignment: .leading)
                    PillButton(title: "Switch", fill: t.ok) { actions.switchTo(suggestion.target) }
                }
                .foregroundStyle(t.warnText).padding(EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 6))
                .background(t.warnBg, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(row.isLive ? t.liveRow : .clear)
        .overlay(alignment: .top) { t.hair.frame(height: 1) }
    }
}

struct GroupView: View {
    let group: GroupRow
    let theme: Theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let name = group.name {
                Text(name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.sub).lineLimit(1).frame(width: 70, alignment: .leading)
            }
            CellView(cell: group.fiveHour, theme: theme)
            CellView(cell: group.sevenDay, theme: theme)
        }
        .frame(height: 24)
    }
}

struct CellView: View {
    let cell: WindowCell
    let theme: Theme

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(cell.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.sub)
                Text(cell.percentText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 2)
                Text(cell.resetText).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(theme.ter).lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    Capsule().fill(theme.bar(cell.band)).frame(width: proxy.size.width * min(1, max(0, cell.fill)))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Small pieces

/// Each tool's own icon, from the app's Resources (copied from CodexBar, MIT): a white silhouette for the menubar,
/// brand colours elsewhere. Nil outside the app bundle (tests, `swift run`), where the letter marks stand in.
@MainActor enum ToolIcon {
    private static var cache: [String: NSImage] = [:]

    static func brand(_ tool: Tool) -> NSImage? { load("ToolBrand-\(tool.rawValue)", ["svg", "png"], template: false) }
    static func glyph(_ tool: Tool) -> NSImage? { load("ToolIcon-\(tool.rawValue)", ["svg"], template: true) }

    private static func load(_ name: String, _ extensions: [String], template: Bool) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = extensions.lazy.compactMap({ Bundle.main.url(forResource: name, withExtension: $0) }).first,
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        cache[name] = image
        return image
    }
}

struct ToolMark: View {
    let tool: Tool
    let size: CGFloat

    var body: some View {
        if let icon = ToolIcon.brand(tool) {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
        } else {
            Text(tool.letter).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white)
                .frame(width: size, height: size).background(Theme.accent(tool), in: RoundedRectangle(cornerRadius: size * 0.28))
        }
    }
}

struct Chip: View {
    let text: String
    let theme: Theme

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.sub).lineLimit(1)
            .padding(.horizontal, 5).frame(height: 16).background(theme.chip, in: RoundedRectangle(cornerRadius: 4)).fixedSize()
    }
}

struct BadgeView: View {
    let badge: RowBadge
    let theme: Theme
    /// The stale / not-fetched badge's tooltip.
    var help: String?

    var body: some View {
        content.fixedSize().help(help ?? "")
    }

    @ViewBuilder private var content: some View {
        switch badge {
        case .stale(let age):
            Label(age, systemImage: "clock").labelStyle(TightLabel()).font(.system(size: 10.5)).foregroundStyle(theme.ter)
        case .notFetched:
            Label("Not fetched", systemImage: "exclamationmark.circle").labelStyle(TightLabel())
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.warnText)
        case .kept:
            Chip(text: "Kept", theme: theme)
        case .needsSignIn, .appNeedsUpdate, .incomplete, .unreadable:
            Label(Self.blockedText(badge), systemImage: "exclamationmark.triangle").labelStyle(TightLabel())
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.deadText)
                .padding(.horizontal, 7).frame(height: 18).background(theme.deadBg, in: Capsule())
        }
    }

    static func blockedText(_ badge: RowBadge) -> String {
        switch badge {
        case .appNeedsUpdate: "App needs update"
        case .incomplete: "Incomplete identity"
        case .unreadable: "Unreadable vault entry"
        default: "Needs sign-in"
        }
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

struct PillButton: View {
    let title: String
    let fill: Color
    var foreground: Color = .white
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(foreground)
                .padding(.horizontal, 10).frame(height: 22).background(fill, in: Capsule())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

struct SquareButton: View {
    let symbol: String
    let help: String
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                .frame(width: 30, height: 30).background(theme.btn, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

/// Its arrow turns clockwise while `action` runs or `active` is true (e.g. the account is being fetched for another
/// reason): at least one full turn, always coming to rest upright.
struct RefreshButton<Content: View>: View {
    let action: @MainActor () async -> Void
    var active = false
    @ViewBuilder let content: (Angle) -> Content
    @State private var turns = 0.0
    @State private var running = false
    /// `active` as state, so the spin loop reads its current value.
    @State private var external = false
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard !running else { return }
            running = true
            spin()
            Task {
                await action()
                running = false
            }
        } label: {
            content(.degrees(turns * 360))
        }
        .onChange(of: active, initial: true) {
            external = active
            if active { spin() }
        }
    }

    /// One loop of whole turns, until neither the action nor `active` holds.
    private func spin() {
        guard !spinning, !reduceMotion else { return }
        spinning = true
        Task {
            repeat {
                withAnimation(.linear(duration: 0.8)) { turns += 1 }
                try? await Task.sleep(for: .milliseconds(800))
            } while running || external
            spinning = false
        }
    }
}

struct NoticeView<Extra: View>: View {
    let theme: Theme
    let icon: String
    let tint: Color
    let background: Color
    let text: String
    let onDismiss: (() -> Void)?
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(theme.sub).accessibilityLabel("Dismiss")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10).padding(.bottom, 10)
    }
}
