import Foundation

public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
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

    private var loop: Task<Void, Never>?
    private var batch: Task<Void, Never>?
    private var inFlight: [AccountKey: Task<Void, Never>] = [:]
    /// Accounts the running batch has yet to fetch, with the callers waiting for that fetch.
    private var queued: [AccountKey: [CheckedContinuation<Void, Never>]] = [:]
    private var lastDelay: [Tool: TimeInterval] = [:]
    /// The payload an account had when it was flagged; new bytes clear the flag.
    private var flaggedPayload: [AccountKey: String] = [:]
    /// The previous interval batch's Claude live read (Keychain bytes, `oauthAccount` bytes).
    private var claudeBaseline: (bytes: Data, account: Data?)?

    public init(state: AppState, tools: [any ToolAdapter], vault: Vault, fetcher: AllowanceFetcher,
                sleeper: any Sleeper, now: @escaping @Sendable () -> Date, renewer: Renewer? = nil) {
        self.state = state
        self.tools = Dictionary(tools.map { ($0.tool, $0) }, uniquingKeysWith: { first, _ in first })
        self.vault = vault
        self.fetcher = fetcher
        self.sleeper = sleeper
        self.now = now
        self.renewer = renewer
    }

    /// One batch now, then forever: sleep the interval → batch.
    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.runBatch()
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

    /// Each tool's live login only.
    public func refreshLive() async {
        for tool in Tool.allCases {
            guard let adapter = tools[tool] else { continue }
            let live = await adapter.readLive()
            state.live[tool] = live
            if case .signedIn(let login) = live {
                let key = AccountKey(tool: tool, id: login.identity.fileID)
                await fetchOnce(key) { await self.fetchLive(key, login) }
                if tool != .claude { await syncBack(tool, seen: login, baseline: nil) }
            }
        }
        state.lastLiveFetch = now()
    }

    /// That account only; a live account reads its live login.
    public func refresh(_ key: AccountKey) async {
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
                await fetchOnce(key, fromBatch: true) { await self.fetchLive(key, login) }
                done(key)
                if tool == .claude { claudeBaseline = (login.bytes, login.claudeAccount) }
                await syncBack(tool, seen: login, baseline: baseline)
            }
            if let previousLive { done(previousLive) }
            for envelope in plan[tool]! {
                let key = AccountKey(tool: tool, id: envelope.identity.fileID)
                if key != liveKey { await fetchOnce(key, fromBatch: true) { await self.fetchSaved(key, envelope) } }
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
        await task.value
        inFlight[key] = nil
    }

    // MARK: - Fetches

    private func fetchLive(_ key: AccountKey, _ login: LiveLogin) async {
        guard !skipFetch(key) else { return }
        guard let token = login.tokens.accessToken, (login.tokens.accessTokenExpiry ?? .distantFuture) > now() else {
            return state.update(key) { $0.stale = true }
        }
        apply(await fetcher.fetch(key.tool, accountKey: key.id, accessToken: token, accountID: login.accountID), to: key)
    }

    /// A saved, non-live account: renewed first when its token is due, and once more after a 401.
    private func fetchSaved(_ key: AccountKey, _ envelope: VaultEnvelope) async {
        let flag = state.status[key]?.flag
        guard flag != .needsSignIn, flag != .appNeedsUpdate, !skipFetch(key) else { return }
        var envelope = envelope
        var tokens = envelope.payloadBytes.flatMap { tokenSet(key.tool, bytes: $0) }
        if let renewer, tokens?.accessToken == nil || (tokens?.accessTokenExpiry ?? .distantFuture) < now().addingTimeInterval(300) {
            guard await renew(key, .nearExpiry(accessToken: tokens?.accessToken ?? ""), renewer, &envelope, &tokens) else { return }
        }
        guard let token = tokens?.accessToken, (tokens?.accessTokenExpiry ?? .distantFuture) > now() else {
            return state.update(key) { $0.stale = true }
        }
        var result = await fetcher.fetch(key.tool, accountKey: key.id, accessToken: token, accountID: envelope.accountID)
        if result == .unauthorized, let renewer {
            guard await renew(key, .unauthorized(accessToken: token), renewer, &envelope, &tokens) else { return }
            if let fresh = tokens?.accessToken, fresh != token {
                result = await fetcher.fetch(key.tool, accountKey: key.id, accessToken: fresh, accountID: envelope.accountID)
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

    /// The vendor is rate limited (the account goes stale), or a Codex reading is under 60 s old.
    private func skipFetch(_ key: AccountKey) -> Bool {
        if let until = state.rateLimitedUntil[key.tool], now() < until {
            state.update(key) { $0.stale = true }
            return true
        }
        if key.tool == .codex, let fetched = state.status[key]?.reading?.fetchedAt, now().timeIntervalSince(fetched) < 60 {
            return true
        }
        return false
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
            lastDelay[key.tool] = nil
            state.rateLimitedUntil[key.tool] = nil
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
            let delay = RateLimitPolicy.nextDelay(previous: lastDelay[key.tool], retryAfter: retryAfter)
            lastDelay[key.tool] = delay
            state.rateLimitedUntil[key.tool] = now().addingTimeInterval(delay)
            state.update(key) { $0.stale = true; $0.error = "rate limited" }
        }
    }
}
