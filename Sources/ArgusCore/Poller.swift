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
    /// Usage requests to one vendor go one at a time, a random time in this range apart (from the previous one's end).
    let spacing: ClosedRange<TimeInterval>
    let pacer: any Sleeper
    /// Picks a value in a range: each request gap and each interval's jitter. Tests pass a fixed pick.
    let random: @Sendable (ClosedRange<Double>) -> Double
    /// Each interval sleep is the chosen interval ± this share, so batches keep no fixed beat.
    static let intervalJitter = 0.1

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
    /// sha256 of the payload an account had when it was flagged; new bytes clear the flag.
    private var flaggedPayload: [AccountKey: String] = [:]
    /// Per Claude context id: the previous interval batch's live read (Keychain bytes, `oauthAccount` bytes).
    private var claudeBaseline: [String: (bytes: Data, account: Data?)] = [:]

    public init(state: AppState, tools: [any ToolAdapter], vault: Vault, fetcher: AllowanceFetcher,
                sleeper: any Sleeper, now: @escaping @Sendable () -> Date, renewer: Renewer? = nil, readingsFile: URL? = nil,
                spacing: ClosedRange<TimeInterval> = 0...0, pacer: any Sleeper = TaskSleeper(),
                random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
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
        self.random = random
        loadReadings()
    }

    private struct PollRecord: Codable {
        let key: AccountKey
        var reading: AllowanceReading?
        var rateLimitedUntil: Date?
        var strikes: Int?
        var backoffEnd: Date?
        var lastAttempt: Date?
        /// A refused sign-in, with the digest of the payload it was refused for; it holds until the saved login changes.
        var needsSignIn: String?
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
            if let digest = r.needsSignIn {
                flaggedPayload[r.key] = digest
                state.update(r.key) { $0.flag = .needsSignIn; $0.stale = true }
            }
        }
    }

    // ponytail: rewrites every record per fetch and keeps removed accounts' records; fine for a handful of accounts.
    private func saveReadings() {
        guard let readingsFile else { return }
        let keys = Set(state.status.keys).union(state.rateLimitedUntil.keys).union(strikes.keys).union(backoffEnd.keys).union(lastAttempt.keys)
        let saved = keys.map { key in
            PollRecord(key: key, reading: state.status[key]?.reading, rateLimitedUntil: state.rateLimitedUntil[key],
                       strikes: strikes[key], backoffEnd: backoffEnd[key], lastAttempt: lastAttempt[key],
                       needsSignIn: state.status[key]?.flag == .needsSignIn ? flaggedPayload[key] : nil)
        }
        if let data = try? JSONEncoder().encode(saved) { _ = writeFileAtomically(data, to: readingsFile) }
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
                let interval = TimeInterval(60 * state.intervalMinutes) * random(1 - Self.intervalJitter...1 + Self.intervalJitter)
                do { try await sleeper.sleep(for: .seconds(interval)) } catch { return }
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

    /// One context's signed-in live login, with the reader it came from.
    private struct LiveRead {
        let context: ToolContext
        let adapter: any ToolAdapter
        let login: LiveLogin
        var key: AccountKey { AccountKey(tool: context.tool, id: login.identity.fileID) }
    }

    /// Reads every context's live login into state. -> the signed-in ones, in context order.
    private func readLive(_ tool: Tool) async -> [LiveRead] {
        guard let base = tools[tool] else { return [] }
        var reads: [LiveRead] = []
        for context in state.contexts(tool) {
            let adapter = base.scoped(to: context)
            let live = await adapter.readLive()
            state.live[tool, default: [:]][context.id] = live
            if case .signedIn(let login) = live { reads.append(LiveRead(context: context, adapter: adapter, login: login)) }
        }
        return reads
    }

    /// One read per account, in order of first appearance: the one whose access token lasts longest (separate sign-ins
    /// in two contexts renew apart; the first context on a tie). It is the one fetched with and synced back from.
    private func freshest(_ reads: [LiveRead]) -> [LiveRead] {
        var chosen: [LiveRead] = [], index: [AccountKey: Int] = [:]
        for read in reads {
            guard let i = index[read.key] else {
                index[read.key] = chosen.count
                chosen.append(read)
                continue
            }
            if read.login.tokens.accessTokenExpiry ?? .distantFuture > chosen[i].login.tokens.accessTokenExpiry ?? .distantFuture { chosen[i] = read }
        }
        return chosen
    }

    /// The saved login to fetch an account with when it is live nowhere: of its copies in the tool's contexts' lists, the
    /// one whose access token lasts longest (the first context on a tie).
    // ponytail: the other copies sit idle, not renewed here, until a switch makes one live and its tool renews it; a
    // vendor expiring unused refresh tokens would need a renewal pass per copy.
    private func savedCopy(_ key: AccountKey) -> (list: ToolContext, envelope: VaultEnvelope)? {
        var best: (list: ToolContext, envelope: VaultEnvelope, expiry: Date)?
        for list in state.contexts(key.tool) {
            guard case .valid(let e)? = state.saved(list).first(where: { $0.id == key.id }), e.identity.isComplete else { continue }
            let expiry = e.payloadBytes.flatMap { tokenSet(key.tool, bytes: $0) }?.accessTokenExpiry ?? .distantFuture
            if best == nil || expiry > best!.expiry { best = (list, e, expiry) }
        }
        return best.map { ($0.list, $0.envelope) }
    }

    /// Each context's live login only, each account fetched once. -> the earliest deferral when every live account's
    /// fetch was deferred.
    @discardableResult
    public func refreshLive() async -> RefreshDeferral? {
        var deferrals: [RefreshDeferral] = [], sent = false
        for tool in Tool.allCases {
            let reads = await readLive(tool)
            for read in freshest(reads) {
                let key = read.key
                if let deferral = deferral(key) { deferrals.append(deferral) } else { sent = true }
                await fetchOnce(key) { await self.fetchLive(key, read.login, in: read.context) }
            }
            if tool != .claude { for read in reads { await syncBack(read, baseline: nil) } }
        }
        return sent ? nil : deferrals.min { $0.until < $1.until }
    }

    /// Each context's live login read again, Codex and agy synced back; no network request (the popover opening).
    public func rereadLive() async {
        for tool in Tool.allCases {
            let reads = await readLive(tool)
            if tool != .claude { for read in reads { await syncBack(read, baseline: nil) } }
        }
    }

    /// That account only; a live account reads its live login. -> why nothing was sent, if so.
    @discardableResult
    public func refresh(_ key: AccountKey) async -> RefreshDeferral? {
        let deferred = deferral(key)
        await refreshNow(key)
        return deferred
    }

    private func refreshNow(_ key: AccountKey) async {
        if !state.liveContexts(key).isEmpty, let read = freshest(await readLive(key.tool)).first(where: { $0.key == key }) {
            return await fetchOnce(key) { await self.fetchLive(key, read.login, in: read.context) }
        }
        await reloadVault()
        guard let copy = savedCopy(key) else { return }
        await fetchOnce(key) { await self.fetchSaved(key, copy.envelope, in: copy.list) }
    }

    /// Re-reads every context's saved logins into state; a flagged account whose saved login changed since (in any
    /// list) is unflagged.
    public func reloadVault() async {
        for tool in Tool.allCases {
            var lists: [String: [VaultEntry]] = [:]
            for context in state.contexts(tool) { lists[context.id] = await vault.entries(context) }
            state.entries[tool] = lists
            for case .valid(let e) in lists.values.joined() {
                let key = AccountKey(tool: tool, id: e.identity.fileID)
                guard let flag = state.status[key]?.flag, flag == .needsSignIn || flag == .appNeedsUpdate,
                      flaggedPayload[key] != sha256Hex(Data(e.payload.utf8)) else { continue }
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
        var plan: [Tool: [AccountKey]] = [:]
        for tool in Tool.allCases {
            // Each saved account once, however many contexts' lists hold it.
            var keys: [AccountKey] = []
            for context in state.contexts(tool) {
                for case .valid(let e) in state.saved(context) where e.identity.isComplete {
                    let key = AccountKey(tool: tool, id: e.identity.fileID), flag = state.status[key]?.flag
                    if flag != .needsSignIn, flag != .appNeedsUpdate, !keys.contains(key) { keys.append(key) }
                }
            }
            plan[tool] = keys
            for key in keys { queued[key, default: []] += [] }
            for key in liveKeys(tool) { queued[key, default: []] += [] }
        }
        for tool in Tool.allCases {
            let previousLive = liveKeys(tool)
            let reads = await readLive(tool)
            let baselines = claudeBaseline
            // Every Claude context's read is the next batch's baseline; one not signed in has none.
            if tool == .claude { claudeBaseline = Dictionary(reads.map { ($0.context.id, ($0.login.bytes, $0.login.claudeAccount)) }) { a, _ in a } }
            var seen: Set<AccountKey> = []
            for read in freshest(reads) {
                let key = read.key
                seen.insert(key)
                await fetchOnce(key, fromBatch: true) { await self.fetchLive(key, read.login, in: read.context, batch: true) }
                done(key)
            }
            // Each context's live login is saved back into its own list.
            for read in reads { await syncBack(read, baseline: baselines[read.context.id]) }
            previousLive.forEach(done)
            for key in plan[tool]! {
                if !seen.contains(key), let copy = savedCopy(key) {
                    await fetchOnce(key, fromBatch: true) { await self.fetchSaved(key, copy.envelope, in: copy.list, batch: true) }
                }
                done(key)
            }
        }
        for key in Array(queued.keys) { done(key) }
    }

    /// The accounts signed in, as last read, across the tool's contexts.
    private func liveKeys(_ tool: Tool) -> Set<AccountKey> {
        Set((state.live[tool] ?? [:]).values.compactMap { live in
            if case .signedIn(let l) = live { AccountKey(tool: tool, id: l.identity.fileID) } else { nil }
        })
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

    private func fetchLive(_ key: AccountKey, _ login: LiveLogin, in context: ToolContext, batch: Bool = false) async {
        guard !skipFetch(key, batch: batch) else { return }
        var token = login.tokens.accessToken
        if (login.tokens.accessTokenExpiry ?? .distantFuture) <= now().addingTimeInterval(key.tool == .agy ? 60 : 0) { token = nil }
        // agy only: an expired live token is replaced by one minted in memory; agy's own login is never written.
        if token == nil, key.tool == .agy, let renewer, let refresh = login.tokens.refreshToken {
            token = await renewer.liveAgyAccessToken(key, refreshToken: refresh, clientID: login.clientID)
        }
        guard let token else {
            let place = context.isDefault ? "" : " in \(context.name)"
            return state.update(key) { $0.stale = true; $0.error = "its sign-in has expired; use \(key.tool.displayName)\(place) once to renew it" }
        }
        lastAttempt[key] = now()
        apply(await paced(key.tool) { await self.fetcher.fetch(key.tool, accountKey: key.id, accessToken: token, accountID: login.accountID) }, to: key)
    }

    /// A saved, non-live account, through its copy in `list`: renewed first when its token is due, and once more after a 401.
    private func fetchSaved(_ key: AccountKey, _ envelope: VaultEnvelope, in list: ToolContext, batch: Bool = false) async {
        let flag = state.status[key]?.flag
        guard flag != .needsSignIn, flag != .appNeedsUpdate, !skipFetch(key, batch: batch) else { return }
        var envelope = envelope
        var tokens = envelope.payloadBytes.flatMap { tokenSet(key.tool, bytes: $0) }
        if let renewer, tokens?.accessToken == nil || (tokens?.accessTokenExpiry ?? .distantFuture) < now().addingTimeInterval(300) {
            guard await renew(key, list, .nearExpiry(accessToken: tokens?.accessToken ?? ""), renewer, &envelope, &tokens) else { return }
        }
        guard let token = tokens?.accessToken, (tokens?.accessTokenExpiry ?? .distantFuture) > now() else {
            return state.update(key) { $0.stale = true; $0.error = "no usable token" }
        }
        lastAttempt[key] = now()
        let accountID = envelope.accountID
        var result = await paced(key.tool) { await self.fetcher.fetch(key.tool, accountKey: key.id, accessToken: token, accountID: accountID) }
        if result == .unauthorized, let renewer {
            guard await renew(key, list, .unauthorized(accessToken: token), renewer, &envelope, &tokens) else { return }
            if let fresh = tokens?.accessToken, fresh != token {
                result = await paced(key.tool) { await self.fetcher.fetch(key.tool, accountKey: key.id, accessToken: fresh, accountID: accountID) }
            }
        }
        apply(result, to: key)
    }

    /// Renews `key`'s copy in `list` and reloads it. -> whether to go on and fetch.
    private func renew(_ key: AccountKey, _ list: ToolContext, _ trigger: RenewalTrigger, _ renewer: Renewer,
                       _ envelope: inout VaultEnvelope, _ tokens: inout TokenSet?) async -> Bool {
        switch await renewer.renew(key, in: list, trigger: trigger, vault: vault, contexts: state.contexts(key.tool)) {
        case .renewed, .skipped:
            guard case .valid(let fresh)? = await vault.entry(list, id: key.id) else { return false }
            envelope = fresh
            tokens = fresh.payloadBytes.flatMap { tokenSet(key.tool, bytes: $0) }
            return true
        case .refused:
            mark(key, .needsSignIn, payload: envelope.payload)
            return false
        case .appNeedsUpdate:
            for case .valid(let e) in (state.entries[.agy] ?? [:]).values.joined() where e.clientId == envelope.clientId {
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
        flaggedPayload[key] = sha256Hex(Data(payload.utf8))
        state.update(key) { $0.flag = flag; $0.stale = true }
        saveReadings()
    }

    /// Runs `send` after every earlier usage request to `tool` has finished and a gap drawn from `spacing` has passed since the last.
    private func paced(_ tool: Tool, _ send: @escaping @MainActor () async -> FetchResult) async -> FetchResult {
        let previous = vendorTail[tool], gap = random(spacing)
        let request = Task { () -> FetchResult in
            await previous?.value
            if let last = lastSent[tool], case let wait = gap - now().timeIntervalSince(last), wait > 0 {
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

    /// Nil when `key` may be fetched now. A batch may come as early as the interval's jitter allows: the interval sleep
    /// starts once the whole batch is done, so an account's next batch request is never sooner than that.
    private func deferral(_ key: AccountKey, batch: Bool = false) -> RefreshDeferral? {
        let now = now()
        if let until = state.rateLimitedUntil[key], now < until { return RefreshDeferral(until: until, rateLimitedBy: key.tool) }
        let gap = minimumGap(key)
        guard let last = [lastAttempt[key], state.status[key]?.reading?.fetchedAt].compactMap({ $0 }).max(),
              now.timeIntervalSince(last) < gap * (batch ? 1 - Self.intervalJitter : 1) else { return nil }
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

    /// Copies a context's changed live bytes into the account's entry in that context's own list, re-checked inside the
    /// tool's exclusive section. Claude writes only when the in-section read equals the previous interval batch's read.
    private func syncBack(_ read: LiveRead, baseline: (bytes: Data, account: Data?)?) async {
        let tool = read.context.tool, list = read.context, login = read.login, adapter = read.adapter
        guard login.identity.isComplete,
              case .valid(let entry)? = state.saved(list).first(where: { $0.id == login.identity.fileID }),
              entry.payloadBytes != login.bytes, tool != .claude || baseline != nil else { return }
        let vault = vault, id = login.identity.fileID
        let wrote = (try? await vault.exclusive(tool) { () async -> Bool in
            guard case .signedIn(let fresh) = await adapter.readLive(), fresh.identity.isComplete, fresh.identity.fileID == id,
                  case .valid(let current)? = await vault.entry(list, id: id), current.identityKey == fresh.identity.key,
                  current.payloadBytes != fresh.bytes else { return false }
            if tool == .claude {
                guard let baseline, fresh.bytes == baseline.bytes, fresh.claudeAccount == baseline.account else { return false }
            }
            return (try? await vault.save(.signedIn(fresh), in: list, origin: .syncBack)) != nil
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
            // "Live updated" means a live reading arrived, not that one was asked for.
            if !state.liveContexts(key).isEmpty { state.lastLiveFetch = now() }
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
