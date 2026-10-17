import Foundation

public enum SwitchStep: String, Sendable, CaseIterable {
    /// The outgoing login's vault write.
    case syncBack
    case writeClaudeKeychain, writeClaudeConfig
    case writeCodexAuth
    case writeAgyKeychain, writeAgyTokenFile, writeAgySettings
    case verify
}

public struct SwitchFaults: Sendable {
    /// That step fails before it writes (verify: fails after reading).
    public var failAt: SwitchStep?
    /// Runs after every write, before the verify reads.
    public var beforeVerify: (@Sendable () async -> Void)?

    public init(failAt: SwitchStep? = nil, beforeVerify: (@Sendable () async -> Void)? = nil) {
        self.failAt = failAt
        self.beforeVerify = beforeVerify
    }
}

public enum SwitchOutcome: Sendable, Equatable {
    case switched(notice: String, offersRestart: Bool)
    case noOp
    /// Nothing written.
    case refused(String)
    /// A write or verify failed; live stores restored.
    case failed(String)
}

public struct ProcessListing: Sendable {
    public let lines: @Sendable () -> [String]

    /// `ps -A -o pid= -o args=` lines: "<pid> <args>".
    public init(lines: @escaping @Sendable () -> [String]) {
        self.lines = lines
    }

    public static let system = ProcessListing {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "pid=", "-o", "args="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

public enum CodexProcesses {
    public static func daemonRunning(_ lines: [String]) -> Bool {
        lines.contains { isDaemon(arguments($0)) }
    }

    public static func desktopAppRunning(_ lines: [String]) -> Bool {
        lines.contains { line in
            let args = arguments(line)
            guard !isDaemon(args), let first = args.first, first.contains(".app/Contents/"), first.hasSuffix("/codex"),
                  let server = args.firstIndex(of: "app-server") else { return false }
            return server + 1 == args.count || args[server + 1].hasPrefix("-")
        }
    }

    /// The `codex` executable of a running managed app-server daemon.
    public static func daemonExecutable(_ lines: [String]) -> URL? {
        for line in lines {
            let args = arguments(line)
            guard isDaemon(args), let codex = args.first(where: { $0.split(separator: "/").last == "codex" }) else { continue }
            return URL(fileURLWithPath: codex)
        }
        return nil
    }

    /// The arguments after the pid.
    private static func arguments(_ line: String) -> [String] {
        Array(line.split(separator: " ").dropFirst().map(String.init))
    }

    private static func isDaemon(_ args: [String]) -> Bool {
        guard let codex = args.firstIndex(where: { $0.split(separator: "/").last == "codex" }),
              let server = args[(codex + 1)...].firstIndex(of: "app-server") else { return false }
        return args[(server + 1)...].contains { $0 == "--managed-daemon" || $0.hasPrefix("--managed-daemon=") }
    }
}

public enum CodexDaemon {
    /// Runs `<executable> app-server daemon restart` with CODEX_HOME set, stdin from /dev/null; nil on success, else the last output line.
    public static func restart(executable: URL, codexHome: URL) async -> String? {
        // `env` adds CODEX_HOME to the inherited environment.
        let outcome = await SecurityCLI(executable: URL(fileURLWithPath: "/usr/bin/env"))
            .run(arguments: ["CODEX_HOME=\(codexHome.path)", executable.path, "app-server", "daemon", "restart"], stdin: nil, timeout: .seconds(30))
        switch outcome {
        case .exited(0, _, _): return nil
        case .exited(let status, let out, let err):
            let lines = (String(decoding: out, as: UTF8.self) + "\n" + String(decoding: err, as: UTF8.self))
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.last ?? "exited with status \(status)"
        case .timedOut: return "timed out"
        case .launchFailed(let why): return why
        }
    }
}

/// Swaps a tool's live login for a saved one, in place, inside that tool's exclusive section.
public struct Switcher: Sendable {
    let env: ToolEnvironment
    let vault: Vault
    let processes: ProcessListing
    let lockTiming: ClaudeLockTiming
    let faults: SwitchFaults
    let now: @Sendable () -> Date

    public init(env: ToolEnvironment, vault: Vault, processes: ProcessListing,
                lockTiming: ClaudeLockTiming = .standard, faults: SwitchFaults = SwitchFaults(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.env = env
        self.vault = vault
        self.processes = processes
        self.lockTiming = lockTiming
        self.faults = faults
        self.now = now
    }

    public func switchTo(_ key: AccountKey) async -> SwitchOutcome {
        do {
            return try await vault.exclusive(key.tool) { await transaction(key) }
        } catch {
            return .failed("Switch failed")
        }
    }

    // MARK: - Transaction

    private enum Snapshot {
        case keychain(service: String, account: String, before: Data?)
        case file(URL, before: Data?)
    }

    private static let mcpKeys = ["mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp", "mcpXaaIdpConfig", "pluginSecrets"]

    private var claude: ClaudeTool { ClaudeTool(env: env) }
    private var keychain: Keychain { env.keychainClient }

    private func adapter(_ tool: Tool) -> any ToolAdapter {
        switch tool {
        case .claude: claude
        case .codex: CodexTool(env: env)
        case .agy: AgyTool(env: env)
        }
    }

    private func transaction(_ key: AccountKey) async -> SwitchOutcome {
        let target: VaultEnvelope
        switch await vault.entry(key.tool, id: key.id) {
        case nil: return .refused("That saved account is gone.")
        case .unreadable: return .refused("Unreadable vault entry")
        case .valid(let e):
            guard e.identity.isComplete, e.tool == key.tool, e.tool != .claude || e.claudeAccount != nil else {
                return .refused("Incomplete identity")
            }
            target = e
        }
        guard let payload = target.payloadBytes else { return .refused("Unreadable vault entry") }
        var held: HeldLocks?
        if key.tool == .claude {
            held = await ClaudeLocks(home: env.home, configURL: claude.configURL, timing: lockTiming, now: now).acquire()
            if held == nil { return .refused("Claude Code is updating its login — try again in a moment. Nothing was written.") }
        }
        defer { held?.release() }
        return await swap(to: target, payload: payload)
    }

    private func swap(to target: VaultEnvelope, payload: Data) async -> SwitchOutcome {
        let tool = target.tool
        let name = tool.displayName
        let live = await adapter(tool).readLive()
        switch live {
        case .unknown:
            return .refused("\(name)'s login can't be read right now, so switching \(name) is paused. Nothing was written — retry in a moment.")
        case .unsupported:
            return .refused("\(name) uses an unsupported storage mode, so switching is paused. Nothing was written.")
        case .signedIn(let login) where login.identity.key == target.identityKey:
            return .noOp
        default:
            break
        }
        var outgoing = "the previous login"
        if case .signedIn(let login) = live {
            if !login.label.isEmpty { outgoing = login.label }
            guard faults.failAt != .syncBack, await keepOutgoing(live, login) else {
                return .failed("Switch failed — \(name) still uses \(outgoing)")
            }
        }
        var snapshots: [Snapshot] = []
        var written = await write(target, payload: payload, snapshots: &snapshots)
        if written.ok {
            await faults.beforeVerify?()
            written.ok = await verify(target, payload: payload, written: written.claudeKeychain)
        }
        guard written.ok else {
            await restore(snapshots)
            return .failed("Switch failed — \(name) still uses \(outgoing)")
        }
        return notice(target)
    }

    /// Step 3: the outgoing login is synced back to its entry, or kept as a new one.
    private func keepOutgoing(_ live: LiveState, _ login: LiveLogin) async -> Bool {
        do {
            if !login.identity.isComplete {
                try await vault.save(live, origin: .kept, allowIncomplete: true)
            } else if case .valid = await vault.entry(login.identity.tool, id: login.identity.fileID) {
                try await vault.save(live, origin: .syncBack)
            } else {
                try await vault.save(live, origin: .kept)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Writes

    private func write(_ target: VaultEnvelope, payload: Data, snapshots: inout [Snapshot]) async -> (ok: Bool, claudeKeychain: Data?) {
        switch target.tool {
        case .claude:
            let service = ClaudeTool.service, account = claude.keychainAccount
            guard faults.failAt != .writeClaudeKeychain, let before = await keychainSnapshot(service, account),
                  let value = Self.claudeItem(target: payload, live: before) else { return (false, nil) }
            snapshots.append(.keychain(service: service, account: account, before: before))
            guard await keychain.write(service: service, account: account, value: value) == .written else { return (false, nil) }
            let config = claude.configURL.resolvingSymlinksInPath()
            guard faults.failAt != .writeClaudeConfig, let current = fileSnapshot(config),
                  let spliced = Self.splice(account: Data(target.claudeAccount!.utf8), into: current) else { return (false, value) }
            snapshots.append(.file(config, before: current))
            return (writeFileAtomically(spliced, to: config), value)
        case .codex:
            let auth = env.codexHome.appending(path: "auth.json")
            guard faults.failAt != .writeCodexAuth, let before = fileSnapshot(auth) else { return (false, nil) }
            snapshots.append(.file(auth, before: before))
            return (writeFileAtomically(payload, to: auth), nil)
        case .agy:
            guard faults.failAt != .writeAgyKeychain, let before = await keychainSnapshot(AgyTool.service, AgyTool.account) else { return (false, nil) }
            snapshots.append(.keychain(service: AgyTool.service, account: AgyTool.account, before: before))
            guard await keychain.write(service: AgyTool.service, account: AgyTool.account, value: payload) == .written else { return (false, nil) }
            let folder = agyFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tokenFile = folder.appending(path: "antigravity-oauth-token")
            guard faults.failAt != .writeAgyTokenFile, let token = agyTokenJSON(payload), let tokenBefore = fileSnapshot(tokenFile) else { return (false, nil) }
            snapshots.append(.file(tokenFile, before: tokenBefore))
            guard writeFileAtomically(token, to: tokenFile) else { return (false, nil) }
            let settings = folder.appending(path: "settings.json")
            guard faults.failAt != .writeAgySettings, let settingsBefore = fileSnapshot(settings) else { return (false, nil) }
            guard let old = settingsBefore else { return (true, nil) }
            guard var json = jsonObject(old) else { return (false, nil) }
            guard json.removeValue(forKey: "modelProvider") != nil else { return (true, nil) }
            snapshots.append(.file(settings, before: old))
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
                return (false, nil)
            }
            return (writeFileAtomically(data, to: settings), nil)
        }
    }

    private var agyFolder: URL { env.home.appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory) }

    /// The Keychain value before the write (nil inside: no item); nil when it can't be read.
    private func keychainSnapshot(_ service: String, _ account: String) async -> Data?? {
        switch await keychain.read(service: service, account: account) {
        case .found(let data): .some(data)
        case .notFound: .some(nil)
        case .unknown: nil
        }
    }

    /// The file's bytes before the write (nil inside: absent); nil when it exists but can't be read.
    private func fileSnapshot(_ url: URL) -> Data?? {
        guard FileManager.default.fileExists(atPath: url.path) else { return .some(nil) }
        return (try? Data(contentsOf: url)).map { .some($0) }
    }

    /// The target's Keychain JSON with Claude Code's MCP and plugin keys taken from the live item (removed when absent live).
    static func claudeItem(target: Data, live: Data?) -> Data? {
        guard var item = jsonObject(target) else { return nil }
        let liveItem = live.flatMap(jsonObject) ?? [:]
        for key in mcpKeys { item[key] = liveItem[key] }
        if NSDictionary(dictionary: item).isEqual(to: jsonObject(target)!) { return target }
        return try? JSONSerialization.data(withJSONObject: item, options: [.withoutEscapingSlashes])
    }

    /// The config text with only the `oauthAccount` value replaced (inserted as the first member when absent).
    static func splice(account: Data, into config: Data?) -> Data? {
        guard let config else { return Data("{\"oauthAccount\":".utf8) + account + Data("}\n".utf8) }
        guard jsonObject(config) != nil else { return nil }
        var bytes = [UInt8](config)
        if let range = topLevelValueRange(of: "oauthAccount", in: config) {
            bytes.replaceSubrange(range, with: account)
            return Data(bytes)
        }
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        let empty = (jsonObject(config)?.isEmpty ?? true)
        bytes.insert(contentsOf: Data("\"oauthAccount\":".utf8) + account + Data((empty ? "" : ",").utf8), at: open + 1)
        return Data(bytes)
    }

    /// agy's token file content: the decoded JSON inside the Keychain envelope, byte for byte.
    private func agyTokenJSON(_ payload: Data) -> Data? {
        let text = String(decoding: payload, as: UTF8.self)
        if text.hasPrefix("go-keyring-base64:") { return Data(base64Encoded: String(text.dropFirst("go-keyring-base64:".count))) }
        if text.hasPrefix("go-keyring-encoded:") { return hexData(String(text.dropFirst("go-keyring-encoded:".count))) }
        return jsonObject(payload) != nil ? payload : nil
    }

    // MARK: - Verify and restore

    private func verify(_ target: VaultEnvelope, payload: Data, written: Data?) async -> Bool {
        let ok: Bool
        switch target.tool {
        case .claude:
            let readBack = await keychain.read(service: ClaudeTool.service, account: claude.keychainAccount)
            let account = claude.readAccount().value as NSDictionary?
            let expected = (try? JSONSerialization.jsonObject(with: Data(target.claudeAccount!.utf8))) as? NSDictionary
            ok = written != nil && readBack == .found(written!) && account != nil && account == expected
        case .codex:
            guard case .signedIn(let login) = await CodexTool(env: env).readLive() else { return false }
            ok = login.identity.key == target.identityKey
        case .agy:
            guard case .signedIn(let login) = await AgyTool(env: env).readLive(),
                  let file = try? Data(contentsOf: agyFolder.appending(path: "antigravity-oauth-token")),
                  let expected = agyTokenJSON(payload).flatMap(jsonObject) else { return false }
            ok = login.identity.key == target.identityKey && jsonObject(file).map { NSDictionary(dictionary: $0) } == NSDictionary(dictionary: expected)
        }
        return ok && faults.failAt != .verify
    }

    private func restore(_ snapshots: [Snapshot]) async {
        for snapshot in snapshots.reversed() {
            switch snapshot {
            case .keychain(let service, let account, let before?):
                _ = await keychain.write(service: service, account: account, value: before)
            case .keychain(let service, let account, nil):
                _ = await keychain.delete(service: service, account: account)
            case .file(let url, let before?):
                _ = writeFileAtomically(before, to: url)
            case .file(let url, nil):
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Notice

    private func notice(_ target: VaultEnvelope) -> SwitchOutcome {
        let email = target.label
        switch target.tool {
        case .claude:
            return .switched(notice: "Claude Code now signs in as \(email). New sessions use it; running ones follow within about 30 s.", offersRestart: false)
        case .agy:
            return .switched(notice: "Antigravity CLI now signs in as \(email) from its next session.", offersRestart: false)
        case .codex:
            let lines = processes.lines()
            let daemon = CodexProcesses.daemonRunning(lines), desktop = CodexProcesses.desktopAppRunning(lines)
            let suffix = switch (daemon, desktop) {
            case (true, true): " The running Codex app-server and Codex desktop app still use the previous account."
            case (true, false): " The running Codex app-server still uses the previous account."
            case (false, true): " The running Codex desktop app still uses the previous account."
            case (false, false): ""
            }
            return .switched(notice: "Codex now signs in as \(email).\(suffix)", offersRestart: daemon)
        }
    }
}
