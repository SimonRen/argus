import AppKit
import MagpieLiteCore
import SwiftUI

/// The popover: header, notices, one card per tool, footer (ui/Main.dc.html).
struct PopoverView: View {
    let state: AppState
    let commands: AccountCommands
    let poller: Poller
    let openManager: () -> Void

    /// Tools whose other accounts are listed; kept until the app quits.
    @State private var expanded: Set<Tool> = []
    @State private var cardsHeight: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(Theme(scheme), now: context.date)
        }
        .frame(width: 392)
    }

    private func content(_ t: Theme, now: Date) -> some View {
        let cards = Tool.allCases.map { tool in
            ToolCard.build(state.snapshot(tool), expanded: expanded.contains(tool), dismissedUnsavedKey: commands.dismissedUnsaved[tool], now: now)
        }
        return VStack(spacing: 0) {
            header(t, now: now)
            notices(t, cards: cards)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(cards, id: \.tool) { CardView(card: $0, theme: t, actions: actions(for: $0.tool)) }
                }
                .padding(.horizontal, 10)
                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .frame(height: min(max(cardsHeight, 1), 470))
            .onPreferenceChange(HeightKey.self) { cardsHeight = $0 }
            footer(t)
        }
        .foregroundStyle(t.text)
    }

    private func header(_ t: Theme, now: Date) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allowance").font(.system(size: 15, weight: .semibold))
                Text(PopoverText.subtitle(lastLiveFetch: state.lastLiveFetch, intervalMinutes: state.intervalMinutes, now: now))
                    .font(.system(size: 11.5)).foregroundStyle(t.sub)
            }
            Spacer()
            HStack(spacing: 6) {
                SquareButton(symbol: "arrow.clockwise", help: "Refresh live accounts", theme: t) { Task { await poller.refreshLive() } }
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
        ForEach(Tool.allCases, id: \.self) { tool in
            if let until = state.rateLimitedUntil[tool], until > Date() {
                let newest = state.snapshot(tool).accounts.compactMap { $0.reading?.fetchedAt }.max()
                NoticeView(theme: t, icon: "clock", tint: t.warnText, background: t.warnBg,
                           text: PopoverText.rateLimitNotice(tool, until: until, newestReading: newest, timeZone: .current), onDismiss: nil) { EmptyView() }
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
            refresh: { key in Task { await poller.refresh(key) } })
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
        let refresh: (AccountKey) -> Void
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
                ForEach(Array(row.badges.enumerated()), id: \.offset) { BadgeView(badge: $0.element, theme: t) }
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
                Button { actions.refresh(row.id) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(t.sub).disabled(!row.refreshEnabled).opacity(row.refreshEnabled ? 1 : 0.4)
                .help("Refresh this account").accessibilityLabel("Refresh \(tool.displayName) \(row.email)")
            }
            .frame(height: 22)
            VStack(spacing: 6) {
                ForEach(Array(row.groups.enumerated()), id: \.offset) { GroupView(group: $0.element, theme: t) }
            }
            .opacity(row.dimmed ? 0.7 : 1)
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

struct ToolMark: View {
    let tool: Tool
    let size: CGFloat

    var body: some View {
        Text(tool.letter).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(Theme.accent(tool), in: RoundedRectangle(cornerRadius: size * 0.28))
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

    var body: some View {
        content.fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch badge {
        case .stale(let age):
            Label(age, systemImage: "clock").labelStyle(TightLabel()).font(.system(size: 10.5)).foregroundStyle(theme.ter)
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
