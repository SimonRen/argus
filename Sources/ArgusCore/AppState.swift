import Foundation
import Observation

public enum AccountFlag: Sendable, Equatable { case ok, needsSignIn, appNeedsUpdate, incomplete, unreadable }

public struct AccountStatus: Sendable, Equatable {
    /// Last good reading.
    public var reading: AllowanceReading?
    /// Last fetch failed, or was skipped by a rate limit or an expired live token.
    public var stale: Bool
    public var error: String?
    public var flag: AccountFlag

    public init(reading: AllowanceReading?, stale: Bool, error: String?, flag: AccountFlag) {
        self.reading = reading
        self.stale = stale
        self.error = error
        self.flag = flag
    }
}

public struct AccountSnapshot: Sendable, Equatable {
    public let key: AccountKey
    public let label: String
    public let plan: String?
    public let isLive: Bool
    public let isSaved: Bool
    public let kept: Bool
    public let flag: AccountFlag
    public let reading: AllowanceReading?
    public let stale: Bool
    /// Its allowance request is in flight.
    public let fetching: Bool
    /// Why the last fetch failed or was skipped, and when its backoff lets it try again.
    public let error: String?
    public let retryAt: Date?

    public init(key: AccountKey, label: String, plan: String?, isLive: Bool, isSaved: Bool, kept: Bool,
                flag: AccountFlag, reading: AllowanceReading?, stale: Bool, fetching: Bool = false, error: String? = nil, retryAt: Date? = nil) {
        self.key = key
        self.label = label
        self.plan = plan
        self.isLive = isLive
        self.isSaved = isSaved
        self.kept = kept
        self.flag = flag
        self.reading = reading
        self.stale = stale
        self.fetching = fetching
        self.error = error
        self.retryAt = retryAt
    }
}

public struct ToolSnapshot: Sendable, Equatable {
    public let tool: Tool
    /// The context's live login; nil before the first read.
    public let live: LiveState?
    /// The context's saved logins, plus an unsaved live login; no order promised.
    public let accounts: [AccountSnapshot]
    public let rateLimitedUntil: Date?
    /// The context shown, and every context of the tool (the default first).
    public let context: ToolContext
    public let contexts: [ToolContext]

    public init(tool: Tool, live: LiveState?, accounts: [AccountSnapshot], rateLimitedUntil: Date?,
                context: ToolContext? = nil, contexts: [ToolContext]? = nil) {
        self.tool = tool
        self.live = live
        self.accounts = accounts
        self.rateLimitedUntil = rateLimitedUntil
        self.context = context ?? .default(tool)
        self.contexts = contexts ?? [self.context]
    }

    /// The context's name while its tool has several, each shown as its own section; else nil.
    public var contextName: String? { contexts.count > 1 ? context.name : nil }
}

extension ToolSnapshot {
    /// The popover's and the menubar's view: agy's "Claude and GPT models" group (a small weekly allowance) is left out;
    /// the manager shows every group.
    public var hidingMinorGroups: ToolSnapshot {
        guard tool == .agy else { return self }
        func major(_ group: AllowanceGroup) -> Bool {
            let name = group.name.lowercased()
            return !name.contains("claude") && !name.contains("gpt")
        }
        let accounts = accounts.map { a in
            AccountSnapshot(key: a.key, label: a.label, plan: a.plan, isLive: a.isLive, isSaved: a.isSaved, kept: a.kept, flag: a.flag,
                            reading: a.reading.map { AllowanceReading(groups: $0.groups.filter(major), plan: $0.plan, fetchedAt: $0.fetchedAt) },
                            stale: a.stale, fetching: a.fetching, error: a.error, retryAt: a.retryAt)
        }
        return ToolSnapshot(tool: tool, live: live, accounts: accounts, rateLimitedUntil: rateLimitedUntil, context: context, contexts: contexts)
    }
}

@MainActor @Observable public final class AppState {
    static let intervalKey = "intervalMinutes"
    static let intervals = [3, 5, 10]

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let now: @Sendable () -> Date

    /// 3, 5 or 10 (defaults key "intervalMinutes"); anything else reads as 5.
    public internal(set) var intervalMinutes: Int
    /// Each tool's added contexts (defaults key "contexts.<tool>"), the default not among them.
    public internal(set) var addedContexts: [Tool: [ToolContext]] = [:]
    /// Per tool, per context id: the live login last read.
    public internal(set) var live: [Tool: [String: LiveState]] = [:]
    /// Per tool, per context id: that context's saved logins.
    public internal(set) var entries: [Tool: [String: [VaultEntry]]] = [:]
    public internal(set) var status: [AccountKey: AccountStatus] = [:]
    /// Per account: no allowance request before this (its 429 backoff). Vendors limit per account, not per vendor.
    public internal(set) var rateLimitedUntil: [AccountKey: Date] = [:]
    /// Accounts whose allowance request is in flight.
    public internal(set) var fetching: Set<AccountKey> = []
    /// When the last live-account fetch completed.
    public internal(set) var lastLiveFetch: Date?

    /// When the live accounts' allowance shown was read: the newest of their readings (kept across launches) and the
    /// last live fetch; nil when there is none.
    public var liveUpdatedAt: Date? {
        let readings = Tool.allCases.flatMap(contexts).compactMap { context -> Date? in
            guard case .signedIn(let login)? = liveState(context) else { return nil }
            return status[AccountKey(tool: context.tool, id: login.identity.fileID)]?.reading?.fetchedAt
        }
        return (readings + [lastLiveFetch].compactMap { $0 }).max()
    }

    public init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        let stored = defaults.integer(forKey: Self.intervalKey)
        intervalMinutes = Self.intervals.contains(stored) ? stored : 5
        for tool in Tool.allCases where tool.supportsContexts {
            addedContexts[tool] = defaults.data(forKey: Self.contextsKey(tool))
                .flatMap { try? JSONDecoder().decode([ToolContext].self, from: $0) }?.filter { $0.tool == tool && !$0.isDefault } ?? []
        }
    }

    static func contextsKey(_ tool: Tool) -> String { "contexts.\(tool.rawValue)" }

    /// The default context, then those added.
    public func contexts(_ tool: Tool) -> [ToolContext] { [.default(tool)] + (addedContexts[tool] ?? []) }

    /// The context's live login; nil before its first read.
    public func liveState(_ context: ToolContext) -> LiveState? { live[context.tool]?[context.id] }

    /// The context's saved logins.
    public func saved(_ context: ToolContext) -> [VaultEntry] { entries[context.tool]?[context.id] ?? [] }

    /// The contexts the account is live in, in `contexts` order.
    public func liveContexts(_ key: AccountKey) -> [ToolContext] {
        contexts(key.tool).filter { context in
            if case .signedIn(let login)? = live[key.tool]?[context.id] { login.identity.fileID == key.id } else { false }
        }
    }

    /// Another context of the tool whose live login runs on this context's refresh token (a copied folder): whichever
    /// renews first signs the other out.
    public func sharesLogin(_ context: ToolContext) -> ToolContext? {
        guard case .signedIn(let mine)? = live[context.tool]?[context.id], let refresh = mine.tokens.refreshToken else { return nil }
        return contexts(context.tool).first { other in
            guard other.id != context.id, case .signedIn(let theirs)? = live[context.tool]?[other.id] else { return false }
            return theirs.tokens.refreshToken == refresh
        }
    }

    /// One context's section: its own saved logins. An account saved in several contexts shares one status.
    public func snapshot(_ context: ToolContext) -> ToolSnapshot {
        let tool = context.tool, contexts = contexts(tool)
        let liveState = liveState(context)
        let liveLogin: LiveLogin? = if case .signedIn(let l) = liveState { l } else { nil }
        let liveID = liveLogin?.identity.fileID
        var accounts: [AccountSnapshot] = saved(context).map { entry in
            let key = AccountKey(tool: tool, id: entry.id)
            switch entry {
            case .valid(let e):
                return account(key, label: e.label, plan: e.plan, isLive: key.id == liveID, isSaved: true, kept: e.kept,
                               derived: e.identity.isComplete ? .ok : .incomplete)
            case .unreadable:
                return account(key, label: "", plan: nil, isLive: key.id == liveID, isSaved: true, kept: false, derived: .unreadable)
            }
        }
        if let liveLogin, let liveID, !accounts.contains(where: { $0.key.id == liveID }) {
            accounts.append(account(AccountKey(tool: tool, id: liveID), label: liveLogin.label, plan: liveLogin.plan, isLive: true,
                                    isSaved: false, kept: false, derived: liveLogin.identity.isComplete ? .ok : .incomplete))
        }
        let toolBackoff = rateLimitedUntil.filter { $0.key.tool == tool }.values.max()
        return ToolSnapshot(tool: tool, live: liveState, accounts: accounts, rateLimitedUntil: toolBackoff, context: context, contexts: contexts)
    }

    private func account(_ key: AccountKey, label: String, plan: String?, isLive: Bool, isSaved: Bool, kept: Bool,
                         derived: AccountFlag) -> AccountSnapshot {
        let s = status[key]
        let flag: AccountFlag = switch s?.flag {
        case .needsSignIn?, .appNeedsUpdate?: s!.flag
        default: derived
        }
        return AccountSnapshot(key: key, label: label, plan: plan, isLive: isLive, isSaved: isSaved, kept: kept,
                               flag: flag, reading: s?.reading, stale: s?.stale ?? false, fetching: fetching.contains(key),
                               error: s?.error, retryAt: rateLimitedUntil[key].flatMap { $0 > now() ? $0 : nil })
    }

    func update(_ key: AccountKey, _ change: (inout AccountStatus) -> Void) {
        var s = status[key] ?? AccountStatus(reading: nil, stale: false, error: nil, flag: .ok)
        change(&s)
        status[key] = s
    }
}
