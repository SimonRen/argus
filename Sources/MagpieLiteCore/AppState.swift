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
    /// nil before the first read.
    public let live: LiveState?
    /// Every vault entry plus an unsaved live login; no order promised.
    public let accounts: [AccountSnapshot]
    public let rateLimitedUntil: Date?

    public init(tool: Tool, live: LiveState?, accounts: [AccountSnapshot], rateLimitedUntil: Date?) {
        self.tool = tool
        self.live = live
        self.accounts = accounts
        self.rateLimitedUntil = rateLimitedUntil
    }
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
        return ToolSnapshot(tool: tool, live: live, accounts: accounts, rateLimitedUntil: rateLimitedUntil)
    }
}

@MainActor @Observable public final class AppState {
    static let intervalKey = "intervalMinutes"
    static let intervals = [3, 5, 10]

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let now: @Sendable () -> Date

    /// 3, 5 or 10 (defaults key "intervalMinutes"); anything else reads as 5.
    public internal(set) var intervalMinutes: Int
    public internal(set) var live: [Tool: LiveState] = [:]
    public internal(set) var entries: [Tool: [VaultEntry]] = [:]
    public internal(set) var status: [AccountKey: AccountStatus] = [:]
    /// Per account: no allowance request before this (its 429 backoff). Vendors limit per account, not per vendor.
    public internal(set) var rateLimitedUntil: [AccountKey: Date] = [:]
    /// Accounts whose allowance request is in flight.
    public internal(set) var fetching: Set<AccountKey> = []
    /// When the last live-account fetch completed.
    public internal(set) var lastLiveFetch: Date?

    public init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        let stored = defaults.integer(forKey: Self.intervalKey)
        intervalMinutes = Self.intervals.contains(stored) ? stored : 5
    }

    public func snapshot(_ tool: Tool) -> ToolSnapshot {
        let liveLogin: LiveLogin? = if case .signedIn(let l) = live[tool] { l } else { nil }
        let liveID = liveLogin?.identity.fileID
        var accounts: [AccountSnapshot] = (entries[tool] ?? []).map { entry in
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
        return ToolSnapshot(tool: tool, live: live[tool], accounts: accounts, rateLimitedUntil: toolBackoff)
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
