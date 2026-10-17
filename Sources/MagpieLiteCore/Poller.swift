import Foundation

public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Why an on-demand refresh sent nothing, and when it may send again.
public struct RefreshDeferral: Sendable, Equatable {
    public let until: Date
    /// The vendor whose 429 backoff holds it; nil when the account was fetched under 60 s ago.
    public let rateLimitedBy: Tool?

    public init(until: Date, rateLimitedBy: Tool?) {
        self.until = until
        self.rateLimitedBy = rateLimitedBy
    }
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Fetches allowance readings: every interval a batch, plus on-demand refreshes. Fetches run one at a time per batch, and
/// a second request for an account already queued or in flight joins the first.
@MainActor public final class Poller {
    let state: AppState
    let tools: [Tool: any ToolAdapter]
    let vault: Vault
    let fetcher: AllowanceFetcher
    let sleeper: any Sleeper
    let now: @Sendable () -> Date
    let renewer: Renewer?
    /// Per account: the last reading, backoff and attempt, kept across launches so a relaunch neither shows dashes
    /// nor hits a blocked account again; nil keeps them in memory only.
    let readingsFile: URL?
    /// Usage requests to one vendor go one at a time, at least this far apart (from the previous one's end).
    let spacing: TimeInterval
    let pacer: any Sleeper

    private var loop: Task<Void, Never>?
    private var batch: Task<Void, Never>?
    private var inFlight: [AccountKey: Task<Void, Never>] = [:]
    /// Accounts the running batch has yet to fetch, with the callers waiting for that fetch.
    private var queued: [AccountKey: [CheckedContinuation<Void, Never>]] = [:]
    /// Per account: consecutive 429s, and when the latest backoff ends (polling stays slower for an hour after).
    /// Per vendor: the end of the request queue, and when its last request finished.
    private var vendorTail: [Tool: Task<Void, Never>] = [:]
    private var lastSent: [Tool: Date] = [:]
    private var strikes: [AccountKey: Int] = [:]
    private var backoffEnd: [AccountKey: Date] = [:]
    /// When each account's last allowance request was sent.
    private var lastAttempt: [AccountKey: Date] = [:]
    /// The payload an account had when it was flagged; new bytes clear the flag.
    private var flaggedPayload: [AccountKey: String] = [:]
    /// The previous interval batch's Claude live read (Keychain bytes, `oauthAccount` bytes).
    private var claudeBaseline: (bytes: Data, account: Data?)?

    public init(state: AppState, tools: [any ToolAdapter], vault: Vault, fetcher: AllowanceFetcher,
                sleeper: any Sleeper, now: @escaping @Sendable () -> Date, renewer: Renewer? = nil, readingsFile: URL? = nil,
                spacing: TimeInterval = 0, pacer: any Sleeper = TaskSleeper()) {
        self.state = state
        self.tools = Dictionary(tools.map { ($0.tool, $0) }, uniquingKeysWith: { first, _ in first })
        self.vault = vault
        self.fetcher = fetcher
        self.sleeper = sleeper
        self.now = now
        self.renewer = renewer
        self.readingsFile = readingsFile
        self.spacing = spacing
        self.pacer = pacer
        loadReadings()
    }

    private struct PollRecord: Codable {
        let key: AccountKey
        var reading: AllowanceReading?
        var rateLimitedUntil: Date?
        var strikes: Int?
        var backoffEnd: Date?
        var lastAttempt: Date?
    }

    /// What the last launch saved: readings shown stale until fetched again, backoffs and attempts still honoured.
    private func loadReadings() {
        guard let readingsFile, let data = try? Data(contentsOf: readingsFile),
              let saved = try? JSONDecoder().decode([PollRecord].self, from: data) else { return }
        for r in saved {
            if let reading = r.reading { state.update(r.key) { $0.reading = reading; $0.stale = true } }
            if let until = r.rateLimitedUntil, until > now() { state.rateLimitedUntil[r.key] = until }
            strikes[r.key] = r.strikes
            backoffEnd[r.key] = r.backoffEnd
            lastAttempt[r.key] = r.lastAttempt
        }
    }

    // ponytail: rewrites every record per fetch and keeps removed accounts' records; fine for a handful of accounts.
    private func saveReadings() {
        guard let readingsFile else { return }
        let keys = Set(state.status.keys).union(state.rateLimitedUntil.keys).union(strikes.keys).union(backoffEnd.keys).union(lastAttempt.keys)
        let saved = keys.map { key in
            PollRecord(key: key, reading: state.status[key]?.reading, rateLimitedUntil: state.rateLimitedUntil[key],
                       strikes: strikes[key], backoffEnd: backoffEnd[key], lastAttempt: lastAttempt[key])
        }
        try? JSONEncoder().encode(saved).write(to: readingsFile, options: .atomic)
    }

    /// One batch now, then forever: sleep the interval → batch.
    public func start() { startLoop(batchFirst: true) }

    /// Restarts a running loop so its next sleep uses the new interval.
    public func intervalDidChange() {
        if loop != nil { startLoop(batchFirst: false) }
    }

    private func startLoop(batchFirst: Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            if batchFirst { await self?.runBatch() }
            while !Task.isCancelled {
                guard let self else { return }
                do { try await sleeper.sleep(for: .seconds(60 * state.intervalMinutes)) } catch { return }
                await runBatch()
            }
        }
    }

    /// Cancels the loop task only.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One batch; a call while a batch runs joins it.
    public func runBatch() async {
        if let batch { return await batch.value }
        let task = Task { await self.batchBody() }
        batch = task
        await task.value
        batch = nil
    }

    /// Each tool's live login only. -> the earliest deferral when every live account's fetch was deferred.
    @discardableResult
    public func refreshLive() async -> RefreshDeferral? {
        var deferrals: [RefreshDeferral] = [], sent = false
        for tool in Tool.allCases {
            guard let adapter = tools[tool] else { continue }
            let live = await adapter.readLive()
            state.live[tool] = live
            if case .signedIn(let login) = live {
                let key = AccountKey(tool: tool, id: login.identity.fileID)
                if let deferral = deferral(key) { deferrals.append(deferral) } else { sent = true }
                await fetchOnce(key) { await self.fetchLive(key, login) }
                if tool != .claude { await syncBack(tool, seen: login, baseline: nil) }
            }
        }
        if sent || deferrals.isEmpty { state.lastLiveFetch = now() }
        return sent ? nil : deferrals.min { $0.until < $1.until }
    }

    /// That account only; a live account reads its live login. -> why nothing was sent, if so.
    @discardableResult
    public func refresh(_ key: AccountKey) async -> RefreshDeferral? {
        let deferred = deferral(key)
        await refreshNow(key)
        return deferred
    }

    private func refreshNow(_ key: AccountKey) async {
        if let adapter = tools[key.tool], case .signedIn(let login) = state.live[key.tool], login.identity.fileID == key.id {
            let live = await adapter.readLive()
            state.live[key.tool] = live
            if case .signedIn(let fresh) = live, fresh.identity.fileID == key.id {
                return await fetchOnce(key) { await self.fetchLive(key, fresh) }
            }
        }
        state.entries[key.tool] = await vault.entries(key.tool)
        guard case .valid(let envelope)? = state.entries[key.tool]?.first(where: { $0.id == key.id }), envelope.identity.isComplete else { return }
        await fetchOnce(key) { await self.fetchSaved(key, envelope) }
    }

    /// Re-reads every tool's vault entries into state; a flagged account whose saved login changed since is unflagged.
    public func reloadVault() async {
        for tool in Tool.allCases {
            let entries = await vault.entries(tool)
            state.entries[tool] = entries
            for case .valid(let e) in entries {
                let key = AccountKey(tool: tool, id: e.identity.fileID)
                guard let flag = state.status[key]?.flag, flag == .needsSignIn || flag == .appNeedsUpdate,
                      flaggedPayload[key] != e.payload else { continue }
                if flag == .appNeedsUpdate {
                    guard let client = e.clientId, OAuthClients.antigravitySecret(forClientID: client) != nil else { continue }
                    if let renewer, await renewer.isBlocked(clientID: client) { continue }
                }
                state.update(key) { $0.flag = .ok }
                flaggedPayload[key] = nil
            }
        }
    }

    // MARK: - Batch

    private func batchBody() async {
        await reloadVault()
        var plan: [Tool: [VaultEnvelope]] = [:]
        for tool in Tool.allCases {
            plan[tool] = (state.entries[tool] ?? []).compactMap { entry in
                guard case .valid(let e) = entry, e.identity.isComplete else { return nil }
                let flag = state.status[AccountKey(tool: tool, id: entry.id)]?.flag
                return flag == .needsSignIn || flag == .appNeedsUpdate ? nil : e
            }
            for e in plan[tool]! { queued[AccountKey(tool: tool, id: e.identity.fileID), default: []] += [] }
            if case .signedIn(let l) = state.live[tool] { queued[AccountKey(tool: tool, id: l.identity.fileID), default: []] += [] }
        }
        for tool in Tool.allCases {
            guard let adapter = tools[tool] else { continue }
            let previousLive: AccountKey? = if case .signedIn(let l) = state.live[tool] { AccountKey(tool: tool, id: l.identity.fileID) } else { nil }
            let live = await adapter.readLive()
            state.live[tool] = live
            var liveKey: AccountKey?
            let baseline = claudeBaseline
            if tool == .claude { claudeBaseline = nil }
            if case .signedIn(let login) = live {
                let key = AccountKey(tool: tool, id: login.identity.fileID)
                liveKey = key
                await fetchOnce(key, fromBatch: true) { await self.fetchLive(key, login, batch: true) }
                done(key)
                if tool == .claude { claudeBaseline = (login.bytes, login.claudeAccount) }
                await syncBack(tool, seen: login, baseline: baseline)
            }
            if let previousLive { done(previousLive) }
            for envelope in plan[tool]! {
                let key = AccountKey(tool: tool, id: envelope.identity.fileID)
                if key != liveKey { await fetchOnce(key, fromBatch: true) { await self.fetchSaved(key, envelope, batch: true) } }
                done(key)
            }
        }
        state.lastLiveFetch = now()
        for key in Array(queued.keys) { done(key) }
    }

    private func done(_ key: AccountKey) {
        queued.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    /// Runs `work` for `key` unless its fetch is already queued in a batch or in flight, in which case this waits for that one.
    private func fetchOnce(_ key: AccountKey, fromBatch: Bool = false, _ work: @escaping @MainActor () async -> Void) async {
        if !fromBatch, queued[key] != nil {
            return await withCheckedContinuation { queued[key]!.append($0) }
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await work() }
        inFlight[key] = task
        state.fetching.insert(key)
        await task.value
        inFlight[key] = nil
        state.fetching.remove(key)
    }

    // MARK: - Fetches

    private func fetchLive(_ key: AccountKey, _ login: LiveLogin, batch: Bool = false) async {
        guard !skipFetch(key, batch: batch) else { return }
        var token = login.tokens.accessToken
        if (login.tokens.accessTokenExpiry ?? .distantFuture) <= now().addingTimeInterval(key.tool == .agy ? 60 : 0) { token = nil }
        // agy only: an expired live token is replaced by one minted in memory; agy's own login is never written.
        if token == nil, key.tool == .agy, let renewer, let refresh = login.tokens.refreshToken {
            token = await renewer.liveAgyAccessToken(key, refreshToken: refresh, clientID: login.clientID)
        }
        guard let token else {
            return state.update(key) { $0.stale = true; $0.error = "its sign-in has expired; use \(key.tool.displayName) once to renew it" }
        }
        lastAttempt[key] = now()
        apply(await paced(key.tool) { await self.fetcher.fetch(key.tool, accountKey: key.id, accessToken: token, accountID: login.accountID) }, to: key)
    }

    /// A saved, non-live account: renewed first when its token is due, and once more after a 401.
    private func fetchSaved(_ key: AccountKey, _ envelope: VaultEnvelope, batch: Bool = false) async {
        let flag = state.status[key]?.flag
        guard flag != .needsSignIn, flag != .appNeedsUpdate, !skipFetch(key, batch: batch) else { return }
        var envelope = envelope
        var tokens = envelope.payloadBytes.flatMap { tokenSet(key.tool, bytes: $0) }
        if let renewer, tokens?.accessToken == nil || (tokens?.accessTokenExpiry ?? .distantFuture) < now().addingTimeInterval(300) {
            guard await renew(key, .nearExpiry(accessToken: tokens?.accessToken ?? ""), renewer, &envelope, &tokens) else { return }
        }
        guard let token = tokens?.accessToken, (tokens?.accessTokenExpiry ?? .distantFuture) > now() else {
            return state.update(key) { $0.stale = true; $0.error = "no usable token" }
        }
        lastAttempt[key] = now()
        let accountID = envelope.accountID
        var result = await paced(key.tool) { await self.fetcher.fetch(key.tool, accountKey: key.id, accessToken: token, accountID: accountID) }
        if result == .unauthorized, let renewer {
            guard await renew(key, .unauthorized(accessToken: token), renewer, &envelope, &tokens) else { return }
            if let fresh = tokens?.accessToken, fresh != token {
                result = await paced(key.tool) { await self.fetcher.fetch(key.tool, accountKey: key.id, accessToken: fresh, accountID: accountID) }
            }
        }
        apply(result, to: key)
    }

    /// Renews `key` and reloads its entry. -> whether to go on and fetch.
    private func renew(_ key: AccountKey, _ trigger: RenewalTrigger, _ renewer: Renewer,
                       _ envelope: inout VaultEnvelope, _ tokens: inout TokenSet?) async -> Bool {
        switch await renewer.renew(key, trigger: trigger, vault: vault) {
        case .renewed, .skipped:
            guard case .valid(let fresh)? = await vault.entry(key.tool, id: key.id) else { return false }
            envelope = fresh
            tokens = fresh.payloadBytes.flatMap { tokenSet(key.tool, bytes: $0) }
            return true
        case .refused:
            mark(key, .needsSignIn, payload: envelope.payload)
            return false
        case .appNeedsUpdate:
            for case .valid(let e) in state.entries[.agy] ?? [] where e.clientId == envelope.clientId {
                mark(AccountKey(tool: .agy, id: e.identity.fileID), .appNeedsUpdate, payload: e.payload)
            }
            mark(key, .appNeedsUpdate, payload: envelope.payload)
            return false
        case .transient(let why):
            state.update(key) { $0.stale = true; $0.error = why }
            return false
        }
    }

    private func mark(_ key: AccountKey, _ flag: AccountFlag, payload: String) {
        flaggedPayload[key] = payload
        state.update(key) { $0.flag = flag; $0.stale = true }
    }

    /// Runs `send` after every earlier usage request to `tool` has finished and `spacing` has passed since the last.
    private func paced(_ tool: Tool, _ send: @escaping @MainActor () async -> FetchResult) async -> FetchResult {
        let previous = vendorTail[tool]
        let request = Task { () -> FetchResult in
            await previous?.value
            if let last = lastSent[tool], case let wait = spacing - now().timeIntervalSince(last), wait > 0 {
                try? await pacer.sleep(for: .seconds(wait))
            }
            let result = await send()
            lastSent[tool] = now()
            return result
        }
        vendorTail[tool] = Task { _ = await request.value }
        return await request.value
    }

    /// The account is backed off (it goes stale), or was asked for under its minimum gap ago.
    private func skipFetch(_ key: AccountKey, batch: Bool) -> Bool {
        guard let deferral = deferral(key, batch: batch) else { return false }
        if deferral.rateLimitedBy != nil { state.update(key) { $0.stale = true } }
        return true
    }

    /// Nil when `key` may be fetched now. A batch may come up to 10% early, so its own timing drift never skips one.
    private func deferral(_ key: AccountKey, batch: Bool = false) -> RefreshDeferral? {
        let now = now()
        if let until = state.rateLimitedUntil[key], now < until { return RefreshDeferral(until: until, rateLimitedBy: key.tool) }
        let gap = minimumGap(key)
        guard let last = [lastAttempt[key], state.status[key]?.reading?.fetchedAt].compactMap({ $0 }).max(),
              now.timeIntervalSince(last) < gap * (batch ? 0.9 : 1) else { return nil }
        return RefreshDeferral(until: last.addingTimeInterval(gap), rateLimitedBy: nil)
    }

    /// The least time between two allowance requests for one account, manual refreshes included. Claude's usage
    /// endpoint allows ~28–30 per account per sliding hour, shared by every client holding its tokens
    /// (refs/claude-swap poll_policy.py): 180 s keeps one account near 20 an hour. For an hour after any account's
    /// backoff ends, 360 s, so clients sharing it settle. Elsewhere 60 s (refs/magpie reuses readings for 1 min).
    private func minimumGap(_ key: AccountKey) -> TimeInterval {
        if let end = backoffEnd[key], now() < end.addingTimeInterval(3600) { return 360 }
        return key.tool == .claude ? 180 : 60
    }

    // MARK: - Poll-time sync-back

    /// Copies a saved live account's changed live bytes into its entry, re-checked inside the tool's exclusive section.
    /// Claude writes only when the in-section read equals the previous interval batch's read.
    private func syncBack(_ tool: Tool, seen login: LiveLogin, baseline: (bytes: Data, account: Data?)?) async {
        guard login.identity.isComplete, let adapter = tools[tool],
              case .valid(let entry)? = state.entries[tool]?.first(where: { $0.id == login.identity.fileID }),
              entry.payloadBytes != login.bytes, tool != .claude || baseline != nil else { return }
        let vault = vault, id = login.identity.fileID
        let wrote = (try? await vault.exclusive(tool) { () async -> Bool in
            guard case .signedIn(let fresh) = await adapter.readLive(), fresh.identity.isComplete, fresh.identity.fileID == id,
                  case .valid(let current)? = await vault.entry(tool, id: id), current.identityKey == fresh.identity.key,
                  current.payloadBytes != fresh.bytes else { return false }
            if tool == .claude {
                guard let baseline, fresh.bytes == baseline.bytes, fresh.claudeAccount == baseline.account else { return false }
            }
            return (try? await vault.save(.signedIn(fresh), origin: .syncBack)) != nil
        }) ?? false
        if wrote { await reloadVault() }
    }

    func apply(_ result: FetchResult, to key: AccountKey) {
        switch result {
        case .reading(let reading):
            strikes[key] = nil
            state.rateLimitedUntil[key] = nil
            state.update(key) {
                $0.reading = reading
                $0.stale = false
                $0.error = nil
            }
        case .unauthorized:
            state.update(key) { $0.stale = true; $0.error = "HTTP 401" }
        case .failed(let reason):
            state.update(key) { $0.stale = true; $0.error = reason }
        case .rateLimited(let retryAfter):
            let strike = (strikes[key] ?? 0) + 1
            strikes[key] = strike
            let until = now().addingTimeInterval(RateLimitPolicy.nextDelay(strike: strike, retryAfter: retryAfter))
            backoffEnd[key] = until
            state.rateLimitedUntil[key] = until
            state.update(key) { $0.stale = true; $0.error = "rate limited" }
        }
        saveReadings()
    }
}
