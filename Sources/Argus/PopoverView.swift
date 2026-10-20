import AppKit
import ArgusCore
import SwiftUI

/// The visible height (menu bar and Dock excluded) of the screen the popover opens on; set just before it opens.
@MainActor @Observable final class PopoverScreen {
    var visibleHeight: CGFloat = 800
}

/// The popover: header, notices, one card per tool context, footer (ui/Main.dc.html).
struct PopoverView: View {
    let state: AppState
    let commands: AccountCommands
    let screen: PopoverScreen
    let preferences: MenuBarPreferences
    let openManager: () -> Void

    /// Contexts whose other accounts are listed; kept until the app quits.
    @State private var expanded: Set<ToolContext> = []
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
        let cards = Tool.allCases.flatMap(state.contexts).filter(preferences.isInPopover).map { context in
            ToolCard.build(state.snapshot(context).hidingMinorGroups, expanded: expanded.contains(context), dismissedUnsavedKey: commands.dismissedUnsaved[context],
                           pending: commands.pending[context], now: now)
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
                    ForEach(cards, id: \.context) { CardView(card: $0, theme: t, actions: actions(for: $0.context)) }
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
                Text("Argus").font(.system(size: 15, weight: .semibold))
                Text(commands.hint ?? PopoverText.subtitle(lastLiveFetch: state.liveUpdatedAt, intervalMinutes: state.intervalMinutes, now: now))
                    .font(.system(size: 11.5)).foregroundStyle(commands.hint == nil ? t.sub : t.warnText)
                    .lineLimit(1).minimumScaleFactor(0.85).animation(.easeInOut(duration: 0.2), value: commands.hint)
            }
            Spacer()
            HStack(spacing: 6) {
                RefreshButton(action: { await commands.refreshLive() }) { angle in
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text).rotationEffect(angle)
                        .frame(width: 30, height: 30).background(t.btn, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(HoverStyle(filled: AnyShape(RoundedRectangle(cornerRadius: 9)))).help("Refresh live accounts").accessibilityLabel("Refresh live accounts")
                SquareButton(symbol: "macwindow", help: "Open manager window", theme: t, action: openManager)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 14))
    }

    @ViewBuilder
    private func notices(_ t: Theme, cards: [ToolCard]) -> some View {
        if let notice = commands.notice {
            let problem = commands.noticeIsProblem
            NoticeView(theme: t, icon: problem ? "exclamationmark.triangle" : "checkmark", tint: problem ? t.warnText : t.liveText,
                       background: problem ? t.warnBg : t.notice, text: notice, onDismiss: commands.dismissNotice) {
                if commands.offersRestart {
                    PillButton(title: "Restart app-server", fill: t.ok) { Task { await commands.restartCodexDaemon() } }
                }
            }
        }
        ForEach(cards.filter { $0.unsavedBanner != nil }, id: \.context) { card in
            NoticeView(theme: t, icon: "exclamationmark.triangle", tint: t.warnText, background: t.warnBg, text: card.unsavedBanner!, onDismiss: nil) {
                HStack(spacing: 6) {
                    PillButton(title: card.pending == .saving ? PendingAction.saving.text : "Save login", fill: t.ok, disabled: card.pending != nil) {
                        Task { await commands.save(card.context) }
                    }
                    PillButton(title: "Later", fill: t.btn, foreground: t.text) { commands.later(card.context) }
                }
            }
        }
    }

    private func footer(_ t: Theme) -> some View {
        HStack {
            Button("Manage accounts…", action: openManager)
                .buttonStyle(HoverStyle.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.link)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(HoverStyle.text).font(.system(size: 12)).foregroundStyle(t.sub)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
    }

    private func actions(for context: ToolContext) -> CardView.Actions {
        CardView.Actions(
            toggle: { if expanded.contains(context) { expanded.remove(context) } else { expanded.insert(context) } },
            switchTo: { key in Task { await commands.switchTo(key, in: context) } },
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
                if let name = card.contextName { ContextChip(context: card.context, name: name, theme: t) }
                Spacer()
                if let more = card.moreLabel {
                    Button(action: actions.toggle) {
                        HStack(spacing: 3) {
                            Text(more)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(more == "Live only" ? 180 : 0))
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(t.sub)
                    }
                    .buttonStyle(HoverStyle.text)
                    .accessibilityLabel(more == "Live only" ? "Hide other \(card.tool.displayName) accounts" : "Show other \(card.tool.displayName) accounts")
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
            // Expanded lists every account in a fixed order, the live one in place; collapsed shows only the live one.
            let expanded = card.moreLabel == "Live only"
            if card.liveRow != nil || expanded {
                HStack(spacing: Table.gap) {
                    Text("ACCOUNT").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(card.columns, id: \.self) { Text($0.uppercased()).frame(width: Table.cell) }
                    Color.clear.frame(width: Table.actions, height: 1)
                }
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(t.ter).lineLimit(1)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 5, trailing: 12))
            }
            // The suggested account's own row: its Switch state, also when the card is collapsed.
            let suggested = card.suggestion.flatMap { s in card.rows.first { $0.id == s.target } }
            if let live = card.liveRow, !expanded {
                RowView(row: live, tool: card.tool, columns: card.columns, suggestion: card.suggestion, suggested: suggested, theme: t, actions: actions)
            } else if card.liveRow == nil, let status = card.liveStatusText {
                HStack {
                    Text(status).font(.system(size: 12)).foregroundStyle(t.sub)
                    Spacer()
                }
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .overlay(alignment: .top) { t.hair.frame(height: 1) }
            }
            if expanded {
                ForEach(card.rows) {
                    RowView(row: $0, tool: card.tool, columns: card.columns, suggestion: $0.isLive ? card.suggestion : nil, suggested: suggested, theme: t, actions: actions)
                }
            }
        }
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.hair, lineWidth: 1))
    }
}

/// The card table's widths, shared by its header and rows so the columns line up.
private enum Table {
    static let cell: CGFloat = 56
    static let gap: CGFloat = 6
    /// Switch (24) and refresh (22).
    static let actions: CGFloat = 50
}

struct RowView: View {
    let row: AccountRow
    let tool: Tool
    /// The card's window columns (`ToolCard.columns`).
    let columns: [String]
    let suggestion: Suggestion?
    let suggested: AccountRow?
    let theme: Theme
    let actions: CardView.Actions

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Table.gap) {
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(row.isLive ? t.liveText : .clear).frame(width: 7, height: 7).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail).help(row.email)
                        // Badges beside the plan, or under it when they don't fit.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 5) { subtitle(t); badges(t) }
                            VStack(alignment: .leading, spacing: 2) { subtitle(t); HStack(spacing: 5) { badges(t) } }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let banner = row.banner {
                    let span = CGFloat(columns.count) * Table.cell + CGFloat(columns.count - 1) * Table.gap
                    let problem = PopoverText.problem(tool: tool, error: row.error, retryAt: row.retryAt, now: .now, timeZone: .current)
                    BannerView(banner: banner, theme: t).frame(width: span).help(row.badges.contains(.notFetched) ? problem : "")
                } else {
                    ForEach(Array(row.cells(columns).enumerated()), id: \.offset) { CellView(cell: $0.element, theme: t) }
                }
                HStack(spacing: 4) {
                    // A finished switch keeps its slot on what is now the live row while it shows how it went.
                    if !row.isLive || row.activity != nil {
                        Button { actions.switchTo(row.id) } label: {
                            Group {
                                switch row.activity {
                                case .switched(_, ok: true)?: Image(systemName: "checkmark").foregroundStyle(t.liveText)
                                case .switched(_, ok: false)?: Image(systemName: "exclamationmark.triangle").foregroundStyle(t.warnText)
                                case .some: ProgressView().controlSize(.mini)
                                case nil: Image(systemName: "arrow.left.arrow.right").foregroundStyle(t.text)
                                }
                            }
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24).background(t.btn, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(HoverStyle(filled: AnyShape(RoundedRectangle(cornerRadius: 7))))
                        .disabled(row.switchDisabledReason != nil).opacity(row.switchDisabledReason != nil && row.activity == nil ? 0.4 : 1)
                        .help(row.activity?.text ?? row.switchDisabledReason ?? "Switch \(tool.displayName) to \(row.email)")
                        .accessibilityLabel("Switch \(tool.displayName) to \(row.email)").accessibilityValue(row.activity?.text ?? "")
                    }
                    RefreshButton(action: { await actions.refresh(row.id) }, active: row.isFetching) { angle in
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold)).rotationEffect(angle).frame(width: 22, height: 22)
                    }
                    .buttonStyle(HoverStyle()).foregroundStyle(t.sub).disabled(!row.refreshEnabled).opacity(row.refreshEnabled ? 1 : 0.4)
                    .help("Refresh this account").accessibilityLabel("Refresh \(tool.displayName) \(row.email)")
                }
                .frame(width: Table.actions, alignment: .trailing)
            }
            if let suggestion {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold))
                    Text(suggestion.text).font(.system(size: 11.5)).frame(maxWidth: .infinity, alignment: .leading)
                    if let activity = suggested?.activity {
                        ActivityPill(activity: activity, theme: t)
                    } else {
                        PillButton(title: "Switch", fill: t.ok, disabled: suggested?.switchDisabledReason != nil) { actions.switchTo(suggestion.target) }
                    }
                }
                .foregroundStyle(t.warnText).padding(EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 6))
                .background(t.warnBg, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(row.isLive ? t.liveRow : .clear)
        .overlay(alignment: .top) { t.hair.frame(height: 1) }
    }

    @ViewBuilder private func subtitle(_ t: Theme) -> some View {
        if !row.subtitle.isEmpty { Text(row.subtitle).font(.system(size: 10.5)).foregroundStyle(t.ter).lineLimit(1) }
    }

    @ViewBuilder private func badges(_ t: Theme) -> some View {
        ForEach(Array(row.inlineBadges.enumerated()), id: \.offset) { BadgeView(badge: $0.element, theme: t) }
    }
}

/// A blocked or never-fetched row: one box across the window columns instead of the cells.
struct BannerView: View {
    let banner: RowBanner
    let theme: Theme

    var body: some View {
        Group {
            switch banner {
            case .blocked(let text):
                Label(text, systemImage: "exclamationmark.triangle").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.deadText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.deadBg, in: RoundedRectangle(cornerRadius: 8))
            case .notFetched:
                Label("Not fetched yet", systemImage: "clock").font(.system(size: 11.5)).foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.ter.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .lineLimit(1).labelStyle(TightLabel()).frame(height: 34)
    }
}

/// One table cell: a bar filled by the share used with the percentage on it, the reset time under it.
struct CellView: View {
    let cell: WindowCell
    let theme: Theme

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        theme.track
                        theme.cellFill(cell.band).frame(width: proxy.size.width * min(1, max(0, cell.fill)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(cell.percentText).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(cell.band == .empty ? theme.ter : theme.text)
            }
            .frame(height: 20)
            Text(cell.resetText).font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.ter).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(width: Table.cell)
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

/// A tool's context menu: the selected context's name as a chip, the tool's contexts checked in its menu.
/// The context a card or manager page is the section of, beside the tool's name, in capitals; its variable on hover.
struct ContextChip: View {
    let context: ToolContext
    let name: String
    let theme: Theme

    var body: some View {
        Text(name).textCase(.uppercase).lineLimit(1)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.sub)
            .padding(.horizontal, 6).frame(height: 18).background(theme.chip, in: Capsule()).fixedSize()
            .help(context.assignment ?? "\(context.tool.displayName)'s default folder")
            .accessibilityLabel("\(context.tool.displayName) context: \(name)")
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

/// A switch or remove under way on a row, or how its switch just ended: shown in place of its button, not pressable.
struct ActivityPill: View {
    let activity: PendingAction
    let theme: Theme

    var body: some View {
        let (icon, fill, text): (String?, Color, Color) = switch activity {
        case .switched(_, ok: true): ("checkmark", theme.liveBg, theme.liveText)
        case .switched(_, ok: false): ("exclamationmark.triangle", theme.warnBg, theme.warnText)
        default: (nil, theme.chip, theme.text)
        }
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(activity.text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(text).padding(.horizontal, 9).frame(height: 22).background(fill, in: Capsule())
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
        .buttonStyle(HoverStyle(filled: AnyShape(Capsule()))).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

/// The popover's buttons: lit while hovered, darker while pressed, with the pointing-hand cursor; nothing while disabled.
/// A filled button is lit over its own shape; a bare one gets a soft rounded background `inset` beyond its label.
struct HoverStyle: ButtonStyle {
    var filled: AnyShape?
    var inset = EdgeInsets()

    /// A text button: the highlight reaches a little past the words.
    static let text = HoverStyle(inset: EdgeInsets(top: -3, leading: -6, bottom: -3, trailing: -6))

    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, style: self) }

    private struct HoverBody: View {
        let configuration: Configuration
        let style: HoverStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let tint = Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.2 : hovering ? 0.1 : 0)
            configuration.label
                .background {
                    if style.filled == nil { RoundedRectangle(cornerRadius: 6).fill(tint).padding(style.inset) }
                }
                .overlay { if let shape = style.filled { shape.fill(tint) } }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointerStyle(enabled ? .link : nil)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
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
        .buttonStyle(HoverStyle(filled: AnyShape(RoundedRectangle(cornerRadius: 9)))).help(help).accessibilityLabel(help)
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
                .buttonStyle(HoverStyle()).foregroundStyle(theme.sub).accessibilityLabel("Dismiss")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10).padding(.bottom, 10)
    }
}
