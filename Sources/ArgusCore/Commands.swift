import Foundation
import Observation

public enum SaveResult: Sendable, Equatable {
    case saved(email: String), updated(email: String), refused(String)

    /// The banner text for this result.
    public var message: String {
        switch self {
        case .saved(let email): "Saved \(email)."
        case .updated(let email): "Updated the saved login for \(email)."
        case .refused(let reason): reason
        }
    }
}

/// What the popover and the manager do to accounts: save, switch, dismiss.
@MainActor @Observable public final class AccountCommands {
    @ObservationIgnored let state: AppState
    @ObservationIgnored let poller: Poller
    @ObservationIgnored let vault: Vault
    @ObservationIgnored let tools: [Tool: any ToolAdapter]
    @ObservationIgnored let switcher: Switcher
    /// Restarts the Codex app-server daemon of that context's home; nil on success, else why not.
    @ObservationIgnored let restartDaemon: (@Sendable (ToolContext) async -> String?)?
    /// The Codex context the last switch was into: what Restart restarts.
    @ObservationIgnored private var restartContext = ToolContext.default(.codex)

    /// The last switch or save result, until dismissed.
    public private(set) var notice: String?
    /// The notice offers Restart for a running Codex app-server.
    public private(set) var offersRestart = false
    /// The notice reports something that went wrong (a refusal, a failure), not a success.
    public private(set) var noticeIsProblem = false
    /// The latest app-server restart; only its result is shown.
    @ObservationIgnored private var restartID = 0
    /// A short-lived hint, e.g. after a refresh that came too soon; it clears itself.
    public private(set) var hint: String?
    @ObservationIgnored private var hintTimer: Task<Void, Never>?
    /// Tool → the live identity key "Later" was pressed for.
    public private(set) var dismissedUnsaved: [Tool: String] = [:]
    /// The last removed entry's raw bytes, held only while Undo is possible.
    @ObservationIgnored private var removed: RemovedEntry?
    private var removedEmail: String?

    public init(state: AppState, poller: Poller, vault: Vault, tools: [any ToolAdapter], switcher: Switcher,
                restartDaemon: (@Sendable (ToolContext) async -> String?)? = nil) {
        self.state = state
        self.poller = poller
        self.vault = vault
        self.tools = Dictionary(tools.map { ($0.tool, $0) }, uniquingKeysWith: { first, _ in first })
        self.switcher = switcher
        self.restartDaemon = restartDaemon
    }

    /// Reads the selected context's live login and saves it inside the tool's exclusive section.
    public func save(_ tool: Tool) async -> SaveResult {
        guard let adapter = tools[tool]?.scoped(to: state.selectedContext(tool)) else { return .refused("not signed in") }
        let vault = vault
        let result: SaveResult
        do {
            result = try await vault.exclusive(tool) {
                let envelope = try await vault.save(await adapter.readLive())
                return envelope.generation == 1 ? .saved(email: envelope.label) : .updated(email: envelope.label)
            }
        } catch let error as VaultError {
            result = .refused(error.reason)
        } catch {
            result = .refused("couldn't save")
        }
        await poller.reloadVault()
        if case .refused = result { show(result.message, problem: true) } else { show(result.message) }
        return result
    }

    /// The notice shows as soon as the switch settles; the live refresh, which a running batch can hold up, comes after.
    public func switchTo(_ key: AccountKey) async -> SwitchOutcome {
        let context = state.selectedContext(key.tool)
        let outcome = await switcher.switchTo(key, in: context, alongside: state.contexts(key.tool))
        await poller.reloadVault()
        await poller.rereadLive()
        guard case .switched(let text, let daemonRunning) = outcome else {
            if case .refused(let text) = outcome { show(text, problem: true) }
            if case .failed(let text) = outcome { show(text, problem: true) }
            return outcome
        }
        let refresh = Task { await poller.refreshLive() }
        if key.tool == .codex { restartContext = context }
        if daemonRunning, restartDaemon != nil { await restartCodexDaemon(after: text) } else { show(text) }
        await refresh.value
        return outcome
    }

    /// "Refresh live accounts"; a refresh that sends nothing says why for a few seconds.
    public func refreshLive() async {
        if let deferral = await poller.refreshLive() { flash(deferral) }
    }

    /// An account row's refresh.
    public func refresh(_ key: AccountKey) async {
        if let deferral = await poller.refresh(key) { flash(deferral) }
    }

    private func flash(_ deferral: RefreshDeferral) {
        hint = PopoverText.refreshHint(deferral, now: state.now(), timeZone: .current)
        hintTimer?.cancel()
        hintTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }

    /// Hides the unsaved banner until the tool's live identity changes.
    public func later(_ tool: Tool) {
        if case .signedIn(let login) = state.liveState(tool) { dismissedUnsaved[tool] = login.identity.key }
    }

    public func dismissNotice() {
        notice = nil
        offersRestart = false
        noticeIsProblem = false
    }

    /// Restarts the running Codex app-server so it picks up the new login; `lead` is the switch notice it follows.
    /// A failure offers Restart again; a notice shown meanwhile is left in place.
    public func restartCodexDaemon(after lead: String? = nil) async {
        guard let restartDaemon else { return }
        restartID += 1
        let id = restartID
        let prefix = lead.map { $0 + " " } ?? ""
        let pending = prefix + "Restarting the Codex app-server so open sessions move over; a running reply gets up to a minute to finish."
        show(pending)
        let failure = await restartDaemon(restartContext)
        guard id == restartID, notice == pending else { return }
        if let failure {
            show(prefix + "The Codex app-server didn't restart (\(failure)), so it still uses the previous account.", offersRestart: true, problem: true)
        } else {
            show(prefix + "Restarted the Codex app-server; open sessions reconnect on their own.")
        }
    }

    private func show(_ text: String, offersRestart: Bool = false, problem: Bool = false) {
        notice = text
        self.offersRestart = offersRestart
        noticeIsProblem = problem
    }
}

extension AccountCommands {
    /// "Removed <email>. Its saved login file was deleted." while Undo is possible.
    public var undoBanner: String? { removedEmail.map { "Removed \($0). Its saved login file was deleted." } }

    /// Deletes the saved login inside the tool's exclusive section, keeping its raw bytes for Undo.
    public func remove(_ key: AccountKey) async {
        closeUndo()
        let email: String = if case .valid(let e)? = state.entries[key.tool]?.first(where: { $0.id == key.id }), !e.label.isEmpty {
            e.label
        } else {
            "Unknown account"
        }
        let vault = vault
        if let entry = try? await vault.exclusive(key.tool, { try await vault.remove(key.tool, id: key.id) }) {
            removed = entry
            removedEmail = email
        }
        await poller.reloadVault()
    }

    /// Writes the removed bytes back unless an entry with that id exists by now; the banner closes either way.
    public func undo() async {
        guard let entry = removed else { return }
        closeUndo()
        let vault = vault
        _ = try? await vault.exclusive(entry.tool) { try await vault.restore(entry) }
        await poller.reloadVault()
    }

    /// Drops the held bytes; Undo is no longer possible.
    public func closeUndo() {
        removed = nil
        removedEmail = nil
    }

    /// 3, 5 or 10 minutes: persisted, and the poll loop's next sleep uses it.
    public func setInterval(_ minutes: Int) {
        guard AppState.intervals.contains(minutes) else { return }
        state.defaults.set(minutes, forKey: AppState.intervalKey)
        state.intervalMinutes = minutes
        poller.intervalDidChange()
    }
}

extension AccountCommands {
    /// Adds a context for `tool` at `path`, as the shell exports it (a leading `~/` is expanded, as the shell does);
    /// an empty name takes the folder's. -> why not, else nil. Its live login is read at once (no network).
    public func addContext(_ tool: Tool, path rawPath: String, name rawName: String) async -> String? {
        guard tool.supportsContexts else { return "\(tool.displayName) has no setting for another folder." }
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" || path.hasPrefix("~/") { path = switcher.env.home.path + path.dropFirst() }
        guard path.hasPrefix("/") else { return "Use the full path, as the shell exports it." }
        // Claude Code names its Keychain item after the exact text, but `/x`, `/x/` and a link to it share its files.
        func folder(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let taken = state.contexts(tool).compactMap { c in c.path.map(folder) ?? (tool == .codex ? folder(switcher.env.codexHome.path) : nil) }
        guard !taken.contains(folder(path)) else { return "That folder is already a \(tool.displayName) context." }
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let last = URL(fileURLWithPath: path).lastPathComponent
            name = last.hasPrefix(".") && last.count > 1 ? String(last.dropFirst()) : last
        }
        guard !state.contexts(tool).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return "Another \(tool.displayName) context is named \(name)."
        }
        state.addedContexts[tool, default: []].append(ToolContext(tool: tool, path: path, name: name))
        saveContexts(tool)
        await poller.rereadLive()
        return nil
    }

    /// Forgets an added context (its folder and logins are left alone); a selected one hands over to the default. -> why
    /// not, else nil. Refused while the folder runs on the very login saved for its account and no other context has
    /// that account live: once unwatched, renewing the saved login would spend the token the folder runs on.
    public func removeContext(_ context: ToolContext) async -> String? {
        guard !context.isDefault else { return nil }
        let tool = context.tool
        if case .signedIn(let login)? = await tools[tool]?.scoped(to: context).readLive(), let refresh = login.tokens.refreshToken,
           case .valid(let saved)? = await vault.entry(tool, id: login.identity.fileID),
           saved.payloadBytes.flatMap({ tokenSet(tool, bytes: $0) })?.refreshToken == refresh,
           !state.liveContexts(AccountKey(tool: tool, id: login.identity.fileID)).contains(where: { $0.id != context.id }) {
            let email = login.label.isEmpty ? "its account" : login.label
            return "\(context.name) runs on the login saved for \(email). Once Argus stops reading \(context.name), renewing that saved login "
                + "would sign it out. Sign out of \(tool.displayName) there, or remove the saved login, first."
        }
        // A switch there cut short is finished while the context is still known.
        if tool == .claude { await switcher.settleInterruptedSwitch(contexts: [context]) }
        state.addedContexts[tool]?.removeAll { $0.id == context.id }
        state.live[context.tool]?[context.id] = nil
        if state.selectedContextID[context.tool] == context.id { selectContext(.default(context.tool)) }
        saveContexts(context.tool)
        return nil
    }

    /// The context the popover and the manager show, save from and switch.
    public func selectContext(_ context: ToolContext) {
        state.selectedContextID[context.tool] = context.id
        state.defaults.set(context.id, forKey: AppState.selectedKey(context.tool))
    }

    private func saveContexts(_ tool: Tool) {
        if let data = try? JSONEncoder().encode(state.addedContexts[tool] ?? []) { state.defaults.set(data, forKey: AppState.contextsKey(tool)) }
    }
}
