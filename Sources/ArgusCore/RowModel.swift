import Foundation

public enum Band: Sendable, Equatable { case ok, warn, low, empty }

/// Rounded integer ≥ 40 ok, 15…39 warn, < 15 low; nil → empty.
public func band(_ remaining: Double?) -> Band {
    guard let remaining else { return .empty }
    let shown = Int(remaining.rounded())
    return shown >= 40 ? .ok : shown >= 15 ? .warn : .low
}

public struct WindowCell: Sendable, Equatable {
    /// "5h" or "7d".
    public let label: String
    /// "62%" or "—".
    public let percentText: String
    public let band: Band
    public let resetText: String
    /// 0…1 bar fill: the share used.
    public let fill: Double

    public init(label: String, percentText: String, band: Band, resetText: String, fill: Double) {
        self.label = label
        self.percentText = percentText
        self.band = band
        self.resetText = resetText
        self.fill = fill
    }

    init(label: String, window: AllowanceWindow?, resetText: String) {
        self.init(label: label, percentText: window.map { "\(Int($0.used.rounded()))%" } ?? "—", band: ArgusCore.band(window?.remaining),
                  resetText: resetText, fill: (window?.used ?? 0) / 100)
    }
}

public struct GroupRow: Sendable, Equatable {
    /// nil when the account has one group.
    public let name: String?
    public let fiveHour: WindowCell
    public let sevenDay: WindowCell

    public init(name: String?, fiveHour: WindowCell, sevenDay: WindowCell) {
        self.name = name
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public enum RowBadge: Sendable, Equatable {
    case stale(String), notFetched, needsSignIn, appNeedsUpdate, incomplete, unreadable, kept

    /// Stale or not fetched: its tooltip says why (`PopoverText.problem`).
    public var isFetchProblem: Bool {
        switch self {
        case .stale, .notFetched: true
        default: false
        }
    }
}

public struct AccountRow: Sendable, Equatable, Identifiable {
    public let id: AccountKey
    public let email: String
    /// Upper case: "MAX", "PRO".
    public let plan: String?
    /// Its allowance request is in flight: the row's refresh arrow spins.
    public let isFetching: Bool
    /// For the stale / not-fetched badge's tooltip (`PopoverText.problem`).
    public let error: String?
    public let retryAt: Date?
    public let isLive: Bool
    public let isSaved: Bool
    public let badges: [RowBadge]
    public let groups: [GroupRow]
    /// nil → Switch enabled (live rows show the Live pill instead).
    public let switchDisabledReason: String?
    public let refreshEnabled: Bool

    init(_ account: AccountSnapshot, live: LiveState?, now: Date) {
        id = account.key
        email = account.label.isEmpty ? "Unknown account" : account.label
        plan = account.plan?.uppercased()
        isFetching = account.fetching
        error = account.error
        retryAt = account.retryAt
        isLive = account.isLive
        isSaved = account.isSaved
        var badges: [RowBadge] = []
        if account.stale, let reading = account.reading {
            badges.append(.stale(PopoverText.age(since: reading.fetchedAt, now: now)))
        } else if account.stale, account.flag == .ok {
            badges.append(.notFetched)   // a blocked state's own badge already says why
        }
        let blocked: (RowBadge, String)? = switch account.flag {
        case .needsSignIn: (.needsSignIn, "Needs sign-in")
        case .appNeedsUpdate: (.appNeedsUpdate, "App needs update")
        case .incomplete: (.incomplete, "Incomplete identity")
        case .unreadable: (.unreadable, "Unreadable vault entry")
        case .ok: nil
        }
        if let blocked { badges.append(blocked.0) }
        if account.kept { badges.append(.kept) }
        self.badges = badges
        let readingGroups = account.reading?.groups ?? []
        // agy's groups are model families, named even when only one is shown.
        let named = readingGroups.count > 1 || account.key.tool == .agy
        groups = readingGroups.isEmpty
            ? [GroupRow(name: nil, fiveHour: WindowCell(label: "5h", window: nil, resetText: "—"), sevenDay: WindowCell(label: "7d", window: nil, resetText: "—"))]
            : readingGroups.map { g in
                let fiveReset = g.fiveHour == nil && g.sevenDay != nil ? "weekly only" : PopoverText.resetText(g.fiveHour, now: now)
                return GroupRow(name: named && !g.name.isEmpty ? g.name : nil,
                                fiveHour: WindowCell(label: "5h", window: g.fiveHour, resetText: fiveReset),
                                sevenDay: WindowCell(label: "7d", window: g.sevenDay, resetText: PopoverText.resetText(g.sevenDay, now: now)))
            }
        if let live, !live.allowsSwitch {
            switchDisabledReason = live.statusText(account.key.tool)
        } else {
            switchDisabledReason = blocked?.1
        }
        refreshEnabled = account.isLive || blocked == nil
    }

    /// The lowest present window across groups; nil when there is none.
    static func score(_ account: AccountSnapshot) -> Double? {
        account.reading?.groups.flatMap { [$0.fiveHour?.remaining, $0.sevenDay?.remaining].compactMap { $0 } }.min()
    }
}

public struct Suggestion: Sendable, Equatable {
    public let target: AccountKey
    public let text: String

    public init(target: AccountKey, text: String) {
        self.target = target
        self.text = text
    }
}

public struct ToolCard: Sendable, Equatable {
    public let tool: Tool
    public let liveRow: AccountRow?
    /// `LiveState.statusText` when not signed in / wiped / unknown / unsupported.
    public let liveStatusText: String?
    /// The other accounts, listed when expanded.
    public let others: [AccountRow]
    /// "+N more" collapsed, "Show less" expanded, nil when no other account.
    public let moreLabel: String?
    public let suggestion: Suggestion?
    public let unsavedBanner: String?

    public static func build(_ snapshot: ToolSnapshot, expanded: Bool, dismissedUnsavedKey: String?, now: Date) -> ToolCard {
        let live = snapshot.accounts.first(where: \.isLive)
        let rest = snapshot.accounts.filter { !$0.isLive }
            .sorted { ($0.label.lowercased(), $0.key.id) < ($1.label.lowercased(), $1.key.id) }
        let others = rest.map { AccountRow($0, live: snapshot.live, now: now) }
        var suggestion: Suggestion?
        if let live, !live.stale, let score = AccountRow.score(live), Int(score.rounded()) < 15 {
            var best: (AccountSnapshot, Double)?
            for account in rest where account.isSaved && !account.stale && account.flag == .ok {
                if let s = AccountRow.score(account), s > (best?.1 ?? -1) { best = (account, s) }
            }
            if let (account, s) = best, Int(s.rounded()) >= 40 {
                let email = account.label.isEmpty ? "Unknown account" : account.label
                suggestion = Suggestion(target: account.key, text: "Running low. \(email) has used \(Int((100 - s).rounded()))%.")
            }
        }
        var unsaved: String?
        if case .signedIn(let login)? = snapshot.live, login.identity.isComplete,
           !snapshot.accounts.contains(where: { $0.isSaved && $0.key.id == login.identity.fileID }),
           dismissedUnsavedKey != login.identity.key {
            unsaved = "\(snapshot.tool.displayName) is signed in as \(login.label.isEmpty ? "Unknown account" : login.label), which isn't saved yet."
        }
        let statusText: String? = if let state = snapshot.live, case .signedIn = state { nil } else { snapshot.live?.statusText(snapshot.tool) }
        return ToolCard(tool: snapshot.tool, liveRow: live.map { AccountRow($0, live: snapshot.live, now: now) }, liveStatusText: statusText,
                        others: others, moreLabel: others.isEmpty ? nil : expanded ? "Show less" : "+\(others.count) more",
                        suggestion: suggestion, unsavedBanner: unsaved)
    }
}

public enum PopoverText {
    public static func resetText(_ window: AllowanceWindow?, now: Date) -> String {
        guard let window else { return "—" }
        // Nothing used: the window hasn't started (agy then reports a reset one full window from now).
        if window.remaining >= 100 { return "not started" }
        guard let resetsAt = window.resetsAt else { return "—" }
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        let minutes = seconds / 60, hours = seconds / 3600, days = seconds / 86400
        if seconds < 3600 { return "in \(minutes)m" }
        if seconds < 86400 { return "in \(hours)h \(String(format: "%02d", minutes % 60))m" }
        return "in \(days)d \(hours % 24)h"
    }

    public static func age(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }

    public static func subtitle(lastLiveFetch: Date?, intervalMinutes: Int, now: Date) -> String {
        guard let lastLiveFetch else { return "Not updated yet · every \(intervalMinutes) min" }
        return "Live updated \(age(since: lastLiveFetch, now: now)) · every \(intervalMinutes) min"
    }

    /// Why an account's reading is stale or missing: its stale / not-fetched badge's tooltip.
    public static func problem(tool: Tool, error: String?, retryAt: Date?, now: Date, timeZone: TimeZone) -> String {
        if let retryAt, retryAt > now { return "Rate limited by \(vendor(tool)). Next try at \(clock(retryAt, timeZone))." }
        if let error { return "Couldn't refresh: \(error)." }
        return "Not refreshed this time."
    }

    private static func vendor(_ tool: Tool) -> String {
        switch tool {
        case .claude: "Claude"
        case .codex: "Codex"
        case .agy: "Antigravity"
        }
    }

    private static func clock(_ date: Date, _ timeZone: TimeZone) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm"
        return clock.string(from: date)
    }

    /// The short-lived hint after a refresh that sent nothing.
    public static func refreshHint(_ deferral: RefreshDeferral, now: Date, timeZone: TimeZone) -> String {
        guard let tool = deferral.rateLimitedBy else {
            let seconds = max(1, Int(deferral.until.timeIntervalSince(now).rounded(.up)))
            return "Refreshed moments ago. Try again in " + (seconds < 90 ? "\(seconds) s." : "\((seconds + 59) / 60) min.")
        }
        return "\(vendor(tool)) is rate-limited. Next check at \(clock(deferral.until, timeZone))."
    }
}
