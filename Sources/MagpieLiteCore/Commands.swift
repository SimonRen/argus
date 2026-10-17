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
    @ObservationIgnored let restartDaemon: (@Sendable () async -> String?)?

    /// The last switch or save result, until dismissed.
    public private(set) var notice: String?
    /// The notice offers Restart for a running Codex app-server.
    public private(set) var offersRestart = false
    /// A short-lived hint, e.g. after a refresh that came too soon; it clears itself.
    public private(set) var hint: String?
    @ObservationIgnored private var hintTimer: Task<Void, Never>?
    /// Tool → the live identity key "Later" was pressed for.
    public private(set) var dismissedUnsaved: [Tool: String] = [:]
    /// The last removed entry's raw bytes, held only while Undo is possible.
    @ObservationIgnored private var removed: RemovedEntry?
    private var removedEmail: String?

    public init(state: AppState, poller: Poller, vault: Vault, tools: [any ToolAdapter], switcher: Switcher,
                restartDaemon: (@Sendable () async -> String?)? = nil) {
        self.state = state
        self.poller = poller
        self.vault = vault
        self.tools = Dictionary(tools.map { ($0.tool, $0) }, uniquingKeysWith: { first, _ in first })
        self.switcher = switcher
        self.restartDaemon = restartDaemon
    }

    /// Reads the live login and saves it inside the tool's exclusive section.
    public func save(_ tool: Tool) async -> SaveResult {
        guard let adapter = tools[tool] else { return .refused("not signed in") }
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
        show(result.message)
        return result
    }

    public func switchTo(_ key: AccountKey) async -> SwitchOutcome {
        let outcome = await switcher.switchTo(key)
        await poller.reloadVault()
        await poller.refreshLive()
        switch outcome {
        case .switched(let text, let daemonRunning) where daemonRunning && restartDaemon != nil: await restartCodexDaemon(after: text)
        case .switched(let text, _): show(text)
        case .refused(let text), .failed(let text): show(text)
        case .noOp: break
        }
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
        if case .signedIn(let login) = state.live[tool] { dismissedUnsaved[tool] = login.identity.key }
    }

    public func dismissNotice() {
        notice = nil
        offersRestart = false
    }

    /// Restarts the running Codex app-server so it picks up the new login; `lead` is the switch notice it follows.
    /// A failure offers Restart again; a notice shown meanwhile is left in place.
    public func restartCodexDaemon(after lead: String? = nil) async {
        guard let restartDaemon else { return }
        let prefix = lead.map { $0 + " " } ?? ""
        let pending = prefix + "Restarting the Codex app-server so open sessions move over; a running reply gets up to a minute to finish."
        show(pending)
        let failure = await restartDaemon()
        guard notice == pending else { return }
        if let failure {
            show(prefix + "The Codex app-server didn't restart (\(failure)), so it still uses the previous account.", offersRestart: true)
        } else {
            show(prefix + "Restarted the Codex app-server; open sessions reconnect on their own.")
        }
    }

    private func show(_ text: String, offersRestart: Bool = false) {
        notice = text
        self.offersRestart = offersRestart
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
