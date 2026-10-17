import Foundation
import Testing
import MagpieLiteCore

fileprivate let fastLocks = ClaudeLockTiming(budget: .milliseconds(300), poll: .milliseconds(50), refreshStale: 60, configStale: 10)
fileprivate let claudeService = "Claude Code-credentials"

fileprivate func claudeItem(_ tag: String, mcp: String? = nil, plugin: String? = nil) -> String {
    let mcpJSON = mcp.map { #","mcpOAuth":{"srv":{"accessToken":"\#($0)"}}"# } ?? ""
    let pluginJSON = plugin.map { #","pluginSecrets":{"p":"\#($0)"}"# } ?? ""
    return #"{"claudeAiOauth":{"accessToken":"test-access-\#(tag)","refreshToken":"test-refresh-\#(tag)","expiresAt":1790000000000,"scopes":["user:inference"],"subscriptionType":"max"}\#(mcpJSON)\#(pluginJSON)}"#
}

fileprivate func claudeAccount(_ tag: String) -> String {
    #"{"emailAddress":"\#(tag)@example.com","accountUuid":"acc-\#(tag)","organizationUuid":"org-\#(tag)","displayName":"\#(tag)"}"#
}

fileprivate func claudeConfig(_ account: String) -> String {
    "{\n  \"numStartups\": 3,\n  \"oauthAccount\": \(account),\n  \"theme\": \"dark\",\n  \"projects\": {\"/x\": {\"allowedTools\": []}}\n}\n"
}

fileprivate func codexAuth(_ tag: String, account: String? = nil) -> String {
    let idToken = testJWT(["email": "\(tag)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": account ?? "acct-\(tag)", "chatgpt_plan_type": "plus"]])
    return #"{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","tokens":{"id_token":"\#(idToken)","access_token":"test-access-\#(tag)","refresh_token":"test-refresh-\#(tag)"},"last_refresh":"2026-10-16T10:00:00Z"}"#
}

fileprivate func agyInner(_ tag: String) -> String {
    let idToken = testJWT(["sub": "sub-\(tag)", "email": "\(tag)@example.com", "azp": OAuthClients.antigravityClientID])
    return #"{"token":{"access_token":"test-access-\#(tag)","token_type":"Bearer","refresh_token":"test-refresh-\#(tag)","expiry":"2026-10-17T12:00:00Z"},"auth_method":"consumer","id_token":"\#(idToken)"}"#
}

fileprivate func agyValue(_ tag: String) -> String { "go-keyring-base64:" + Data(agyInner(tag).utf8).base64EncodedString() }

/// Fails Keychain reads (rc 51) while passing everything else to the guarded tool.
fileprivate final class FailingReads: SecurityRunning, @unchecked Sendable {
    let inner: any SecurityRunning
    init(_ inner: any SecurityRunning) { self.inner = inner }
    func run(arguments: [String], stdin: Data?, timeout: Duration) async -> SecurityOutcome {
        if arguments.first == "find-generic-password" { return .exited(status: 51, stdout: Data(), stderr: Data()) }
        return await inner.run(arguments: arguments, stdin: stdin, timeout: timeout)
    }
}

/// Records whether Claude Code's lock directories exist at the first Keychain read.
fileprivate final class LockProbe: SecurityRunning, @unchecked Sendable {
    let inner: any SecurityRunning
    let locks: [URL]
    private let lock = NSLock()
    private var seen: Bool?
    init(_ inner: any SecurityRunning, locks: [URL]) { self.inner = inner; self.locks = locks }
    var heldAtFirstRead: Bool? { lock.withLock { seen } }
    func run(arguments: [String], stdin: Data?, timeout: Duration) async -> SecurityOutcome {
        lock.withLock {
            if seen == nil, arguments.first == "find-generic-password" {
                seen = locks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            }
        }
        return await inner.run(arguments: arguments, stdin: stdin, timeout: timeout)
    }
}

fileprivate actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

fileprivate actor Flag {
    private(set) var value: Bool?
    func set(_ v: Bool) { value = v }
}

fileprivate final class Fixture: @unchecked Sendable {
    let box: TestSandbox
    let vault: Vault

    init() throws {
        box = try TestSandbox()
        vault = try Vault(supportRoot: box.supportRoot)
    }

    var configURL: URL { box.home.appending(path: ".claude.json") }
    var authURL: URL { box.codexHome.appending(path: "auth.json") }
    var agyFolder: URL { box.home.appending(path: ".gemini/antigravity-cli") }
    var lockURLs: [URL] {
        [box.home.appending(path: ".claude/.oauth_refresh.lock"), box.home.appending(path: ".claude.lock"), URL(fileURLWithPath: configURL.path + ".lock")]
    }

    func switcher(faults: SwitchFaults = SwitchFaults(), lines: [String] = [], env: ToolEnvironment? = nil) -> Switcher {
        Switcher(env: env ?? box.env, vault: vault, processes: ProcessListing { lines }, lockTiming: fastLocks, faults: faults)
    }

    func seedClaude(_ tag: String, mcp: String? = nil, plugin: String? = nil) async throws {
        try box.write("home/.claude.json", claudeConfig(claudeAccount(tag)))
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem(tag, mcp: mcp, plugin: plugin))) == .written)
    }

    func seedCodex(_ tag: String, account: String? = nil) throws { try box.write("codex/auth.json", codexAuth(tag, account: account)) }

    func seedAgy(_ tag: String) async {
        #expect(await box.keychain.write(service: "gemini", account: "antigravity", value: utf8(agyValue(tag))) == .written)
    }

    func live(_ tool: Tool) async -> LiveState {
        switch tool {
        case .claude: await ClaudeTool(env: box.env).readLive()
        case .codex: await CodexTool(env: box.env).readLive()
        case .agy: await AgyTool(env: box.env).readLive()
        }
    }

    /// Saves the current live login and returns its key.
    @discardableResult
    func saveLive(_ tool: Tool, origin: VaultOrigin = .save) async throws -> AccountKey {
        let envelope = try await vault.save(await live(tool), origin: origin)
        return AccountKey(tool: tool, id: envelope.identity.fileID)
    }

    func liveKey(_ tool: Tool) async -> String? {
        if case .signedIn(let login) = await live(tool) { return login.identity.key }
        return nil
    }

    func claudeKeychain() async -> KeychainRead { await box.keychain.read(service: claudeService, account: "tester") }
    func agyKeychain() async -> KeychainRead { await box.keychain.read(service: "gemini", account: "antigravity") }

    var writes: [TestGuardedSecurity.Call] { (box.guarded?.calls ?? []).filter { $0.words.first != "find-generic-password" } }
}

@Suite struct SwitchTests {
    // MARK: F03-AC-3.c1

    @Test func `REQ/F03-AC-3.c1 switching to the live account writes nothing`() async throws {
        let f = try Fixture()
        try f.seedCodex("a")
        let key = try await f.saveLive(.codex)
        try await f.seedClaude("a")
        let claudeKey = try await f.saveLive(.claude)
        let writesBefore = f.writes.count
        let auth = try Data(contentsOf: f.authURL), config = try Data(contentsOf: f.configURL)
        #expect(await f.switcher().switchTo(key) == .noOp)
        #expect(await f.switcher().switchTo(claudeKey) == .noOp)
        #expect(f.writes.count == writesBefore)
        #expect(try Data(contentsOf: f.authURL) == auth)
        #expect(try Data(contentsOf: f.configURL) == config)
        guard case .valid(let entry) = await f.vault.entry(.codex, id: key.id) else { Issue.record("entry gone"); return }
        #expect(entry.generation == 1)
        #expect(f.box.violations.isEmpty)
    }

    // MARK: F03-AC-3.c2

    @Test func `REQ/F03-AC-3.c2 an unreadable live login refuses the switch with a retry notice and writes nothing`() async throws {
        let f = try Fixture()
        try await f.seedClaude("b")
        let key = try await f.saveLive(.claude)
        try await f.seedClaude("a")
        let writesBefore = f.writes.count
        var env = f.box.env
        env.security = FailingReads(f.box.env.security)
        let outcome = await f.switcher(env: env).switchTo(key)
        #expect(outcome == .refused("Claude Code's login can't be read right now, so switching Claude Code is paused. Nothing was written — retry in a moment."))
        #expect(f.writes.count == writesBefore)
        #expect(await f.liveKey(.claude) == "claude:a@example.com:org-a")
        #expect(f.lockURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func `REQ/F03-AC-3.c2 an unparseable or unsupported Codex login refuses the switch`() async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let key = try await f.saveLive(.codex)
        try f.box.write("codex/auth.json", "{broken")
        #expect(await f.switcher().switchTo(key) == .refused("Codex's login can't be read right now, so switching Codex is paused. Nothing was written — retry in a moment."))
        #expect(try Data(contentsOf: f.authURL) == utf8("{broken"))
        try f.box.write("codex/config.toml", "cli_auth_credentials_store = \"keyring\"\n")
        #expect(await f.switcher().switchTo(key) == .refused("Codex uses an unsupported storage mode, so switching is paused. Nothing was written."))
    }

    @Test func `missing, unreadable and incomplete targets are refused`() async throws {
        let f = try Fixture()
        let missing = AccountKey(tool: .codex, id: String(repeating: "0", count: 64))
        #expect(await f.switcher().switchTo(missing) == .refused("That saved account is gone."))
        try f.box.write("support/vault/codex/\(missing.id).json", "{}")
        #expect(await f.switcher().switchTo(missing) == .refused("Unreadable vault entry"))
        try await f.seedClaude("a")
        try f.box.write("home/.claude.json", "{}")
        let envelope = try await f.vault.save(await f.live(.claude), origin: .kept, allowIncomplete: true)
        #expect(await f.switcher().switchTo(AccountKey(tool: .claude, id: envelope.identity.fileID)) == .refused("Incomplete identity"))
    }

    // MARK: F03-AC-3.c3

    @Test func `REQ/F03-AC-3.c3 a saved outgoing login is synced back with its kept flag before the target is written`() async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let target = try await f.saveLive(.codex)
        try f.seedCodex("a")
        let outgoing = try await f.saveLive(.codex, origin: .kept)
        let refreshed = codexAuth("a").replacingOccurrences(of: "2026-10-16T10:00:00Z", with: "2026-10-17T01:00:00Z")
        try f.box.write("codex/auth.json", refreshed)
        let outcome = await f.switcher(faults: SwitchFaults(failAt: .writeCodexAuth)).switchTo(target)
        #expect(outcome == .failed("Switch failed — Codex still uses a@example.com"))
        guard case .valid(let entry) = await f.vault.entry(.codex, id: outgoing.id) else { Issue.record("entry gone"); return }
        #expect(entry.payloadBytes == utf8(refreshed))
        #expect(entry.kept)
        #expect(entry.origin == .syncBack)
        #expect(try Data(contentsOf: f.authURL) == utf8(refreshed))
        guard case .switched = await f.switcher().switchTo(target) else { Issue.record("switch failed"); return }
        guard case .valid(let after) = await f.vault.entry(.codex, id: outgoing.id) else { Issue.record("entry gone"); return }
        #expect(after.kept && after.payloadBytes == utf8(refreshed))
    }

    // MARK: F03-AC-3.c4

    @Test func `REQ/F03-AC-3.c4 an unsaved outgoing login is kept as a new entry before the target is written`() async throws {
        let f = try Fixture()
        await f.seedAgy("b")
        let target = try await f.saveLive(.agy)
        await f.seedAgy("a")
        guard case .switched = await f.switcher().switchTo(target) else { Issue.record("switch failed"); return }
        let entries = await f.vault.entries(.agy)
        #expect(entries.count == 2)
        let kept = entries.compactMap { if case .valid(let e) = $0, e.identityKey == "agy:sub-a" { e } else { nil } }.first
        #expect(kept?.kept == true)
        #expect(kept?.origin == .kept)
        #expect(kept?.payloadBytes == utf8(agyValue("a")))
        await f.seedAgy("a")
        let resaved = try await f.vault.save(await f.live(.agy))
        #expect(!resaved.kept)
        #expect(f.box.violations.isEmpty)
    }

    // MARK: F03-AC-3.c5

    @Test func `REQ/F03-AC-3.c5 a wiped or absent outgoing login stores nothing and the switch proceeds`() async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let target = try await f.saveLive(.codex)
        try FileManager.default.removeItem(at: f.authURL)
        guard case .switched = await f.switcher().switchTo(target) else { Issue.record("absent: switch failed"); return }
        #expect(await f.vault.entries(.codex).count == 1)
        #expect(try Data(contentsOf: f.authURL) == utf8(codexAuth("b")))

        let g = try Fixture()
        try await g.seedClaude("b")
        let claudeTarget = try await g.saveLive(.claude)
        try g.box.write("home/.claude.json", claudeConfig(claudeAccount("a")))
        #expect(await g.box.keychain.write(service: claudeService, account: "tester", value: utf8(#"{"claudeAiOauth":{"accessToken":"","refreshToken":""}}"#)) == .written)
        #expect(await g.live(.claude) == .wiped)
        guard case .switched = await g.switcher().switchTo(claudeTarget) else { Issue.record("wiped: switch failed"); return }
        #expect(await g.vault.entries(.claude).count == 1)
        #expect(await g.liveKey(.claude) == "claude:b@example.com:org-b")
    }

    // MARK: F03-AC-3.c6

    @Test func `REQ/F03-AC-3.c6 an incomplete outgoing identity is kept as its own entry, never merged`() async throws {
        let f = try Fixture()
        try await f.seedClaude("a")
        let complete = try await f.saveLive(.claude)
        let completeBytes = try Data(contentsOf: f.box.supportRoot.appending(path: "vault/claude/\(complete.id).json"))
        try await f.seedClaude("b")
        let target = try await f.saveLive(.claude)
        try await f.seedClaude("a")
        try f.box.write("home/.claude.json", "{\"numStartups\": 3}\n")
        guard case .switched = await f.switcher().switchTo(target) else { Issue.record("switch failed"); return }
        let entries = await f.vault.entries(.claude)
        #expect(entries.count == 3)
        let incomplete = entries.compactMap { if case .valid(let e) = $0, !e.identity.isComplete { e } else { nil } }
        #expect(incomplete.count == 1)
        #expect(incomplete.first?.kept == true)
        #expect(incomplete.first?.identityKey == "claude:incomplete:" + sha256Hex(utf8("test-refresh-a")))
        #expect(try Data(contentsOf: f.box.supportRoot.appending(path: "vault/claude/\(complete.id).json")) == completeBytes)
        await #expect(throws: VaultError("incomplete identity")) {
            try await f.vault.save(.signedIn(LiveLogin(identity: incomplete[0].identity, plan: nil, label: "", bytes: utf8("x"),
                                                       tokens: TokenSet(accessToken: nil, accessTokenExpiry: nil, refreshToken: nil),
                                                       clientID: nil, claudeAccount: nil, accountID: nil)))
        }
    }

    // MARK: F03-AC-3.c7

    @Test func `REQ/F03-AC-3.c7 a Claude switch writes the Keychain over security -i with live MCP keys and changes only oauthAccount`() async throws {
        let f = try Fixture()
        try await f.seedClaude("b", mcp: "test-mcp-old", plugin: "test-plugin-old")
        let target = try await f.saveLive(.claude)
        try await f.seedClaude("a", mcp: "test-mcp-live")
        let configBefore = try String(contentsOf: f.configURL, encoding: .utf8)
        var env = f.box.env
        let probe = LockProbe(f.box.env.security, locks: f.lockURLs)
        env.security = probe
        let locks = f.lockURLs
        let heldAtVerify = Flag()
        let faults = SwitchFaults(beforeVerify: {
            await heldAtVerify.set(locks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        })
        let writesBefore = f.writes.count
        let outcome = await f.switcher(faults: faults, env: env).switchTo(target)
        #expect(outcome == .switched(notice: "Claude Code now signs in as b@example.com. New sessions use it; running ones follow within about 30 s.", daemonRunning: false))
        #expect(probe.heldAtFirstRead == true)
        #expect(await heldAtVerify.value == true)
        #expect(locks.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        guard case .found(let item) = await f.claudeKeychain(), let json = try JSONSerialization.jsonObject(with: item) as? [String: Any] else {
            Issue.record("no item"); return
        }
        #expect(!item.contains(UInt8(ascii: "\n")))
        #expect((json["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String == "test-refresh-b")
        #expect(((json["mcpOAuth"] as? [String: Any])?["srv"] as? [String: Any])?["accessToken"] as? String == "test-mcp-live")
        #expect(json["pluginSecrets"] == nil)
        let keychainWrites = f.writes.dropFirst(writesBefore).filter { $0.words.first == "add-generic-password" }
        #expect(keychainWrites.count == 1 && keychainWrites.allSatisfy(\.viaStdin))
        let expected = configBefore.replacingOccurrences(of: claudeAccount("a"), with: claudeAccount("b"))
        #expect(try String(contentsOf: f.configURL, encoding: .utf8) == expected)
        #expect((try FileManager.default.attributesOfItem(atPath: f.configURL.path))[.posixPermissions] as? Int == 0o600)
        #expect(await f.liveKey(.claude) == "claude:b@example.com:org-b")
        #expect(f.box.violations.isEmpty)
    }

    @Test func `REQ/F03-AC-3.c7 an existing .credentials.json gets the new Keychain value, an absent one is not created, a failed switch restores it`() async throws {
        for present in [true, false] {
            let f = try Fixture()
            try await f.seedClaude("b")
            let target = try await f.saveLive(.claude)
            try await f.seedClaude("a")
            let shadow = f.box.home.appending(path: ".claude/.credentials.json")
            if present {
                try FileManager.default.createDirectory(at: shadow.deletingLastPathComponent(), withIntermediateDirectories: true)
                try utf8("{\"stale\":true}").write(to: shadow)
            }
            guard case .switched = await f.switcher().switchTo(target) else { Issue.record("switch failed"); return }
            if present {
                guard case .found(let item) = await f.claudeKeychain() else { Issue.record("no item"); return }
                #expect(try Data(contentsOf: shadow) == item)
            } else {
                #expect(!FileManager.default.fileExists(atPath: shadow.path))
            }
        }
        let f = try Fixture()
        try await f.seedClaude("b")
        let target = try await f.saveLive(.claude)
        try await f.seedClaude("a")
        let shadow = f.box.home.appending(path: ".claude/.credentials.json")
        try FileManager.default.createDirectory(at: shadow.deletingLastPathComponent(), withIntermediateDirectories: true)
        try utf8("{\"stale\":true}").write(to: shadow)
        #expect(await f.switcher(faults: SwitchFaults(failAt: .writeClaudeConfig)).switchTo(target) == .failed("Switch failed — Claude Code still uses a@example.com"))
        #expect(try Data(contentsOf: shadow) == utf8("{\"stale\":true}"))
    }

    @Test func `REQ/F03-AC-3.c7 a busy Claude lock refuses after the budget, a stale one is broken`() async throws {
        let f = try Fixture()
        try await f.seedClaude("b")
        let target = try await f.saveLive(.claude)
        try await f.seedClaude("a")
        let configLock = f.lockURLs[2]
        try FileManager.default.createDirectory(at: configLock, withIntermediateDirectories: true)
        let start = Date()
        #expect(await f.switcher().switchTo(target) == .refused("Claude Code is updating its login — try again in a moment. Nothing was written."))
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(!FileManager.default.fileExists(atPath: f.lockURLs[0].path) && !FileManager.default.fileExists(atPath: f.lockURLs[1].path))
        #expect(await f.liveKey(.claude) == "claude:a@example.com:org-a")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: configLock.path)
        guard case .switched = await f.switcher().switchTo(target) else { Issue.record("stale lock not broken"); return }
        #expect(!FileManager.default.fileExists(atPath: configLock.path))
    }

    @Test func `the config splice inserts oauthAccount first when absent and leaves other bytes alone`() async throws {
        let f = try Fixture()
        try await f.seedClaude("b")
        let target = try await f.saveLive(.claude)
        try await f.seedClaude("a")
        try await f.saveLive(.claude)
        try f.box.write("home/.claude.json", "{\n  \"theme\": \"dark\"\n}\n")
        _ = await f.switcher().switchTo(target)
        #expect(try String(contentsOf: f.configURL, encoding: .utf8) == "{\"oauthAccount\":\(claudeAccount("b")),\n  \"theme\": \"dark\"\n}\n")
    }

    // MARK: F03-AC-3.c8

    @Test func `REQ/F03-AC-3.c8 a Codex switch replaces auth.json through a 0600 staged file and leaves other files alone`() async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let target = try await f.saveLive(.codex)
        try f.seedCodex("a")
        try f.box.write("codex/config.toml", "model = \"o3\"\n")
        try f.box.write("codex/sessions/s1.jsonl", "{\"x\":1}\n")
        let others = ["config.toml", "sessions/s1.jsonl"].map { try? Data(contentsOf: f.box.codexHome.appending(path: $0)) }
        let outcome = await f.switcher().switchTo(target)
        #expect(outcome == .switched(notice: "Codex now signs in as b@example.com.", daemonRunning: false))
        #expect(try Data(contentsOf: f.authURL) == utf8(codexAuth("b")))
        #expect((try FileManager.default.attributesOfItem(atPath: f.authURL.path))[.posixPermissions] as? Int == 0o600)
        #expect(["config.toml", "sessions/s1.jsonl"].map { try? Data(contentsOf: f.box.codexHome.appending(path: $0)) } == others)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.box.codexHome.path).sorted()
        #expect(names == ["auth.json", "config.toml", "sessions"])
    }

    // MARK: F03-AC-3.c9

    @Test func `REQ/F03-AC-3.c9 an agy switch writes the Keychain, the token file and drops modelProvider, verified through security`() async throws {
        let f = try Fixture()
        await f.seedAgy("b")
        let target = try await f.saveLive(.agy)
        await f.seedAgy("a")
        try f.box.write("home/.gemini/antigravity-cli/settings.json", #"{"modelProvider":"gemini","theme":"dark","n":2}"#)
        let readsBefore = (f.box.guarded?.calls ?? []).count
        let outcome = await f.switcher().switchTo(target)
        #expect(outcome == .switched(notice: "Antigravity CLI now signs in as b@example.com from its next session.", daemonRunning: false))
        #expect(await f.agyKeychain() == .found(utf8(agyValue("b"))))
        let tokenFile = f.agyFolder.appending(path: "antigravity-oauth-token")
        #expect(try Data(contentsOf: tokenFile) == utf8(agyInner("b")))
        #expect((try FileManager.default.attributesOfItem(atPath: tokenFile.path))[.posixPermissions] as? Int == 0o600)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: f.agyFolder.appending(path: "settings.json"))) as? NSDictionary
        #expect(settings == ["theme": "dark", "n": 2])
        let calls = (f.box.guarded?.calls ?? []).dropFirst(readsBefore).map { $0.words.first ?? "" }
        #expect(calls.lastIndex(of: "find-generic-password")! > calls.lastIndex(of: "add-generic-password")!)
        #expect(f.box.violations.isEmpty)
    }

    @Test func `REQ/F03-AC-3.c9 a missing settings file stays missing and the folder is created owner-only`() async throws {
        let f = try Fixture()
        await f.seedAgy("b")
        let target = try await f.saveLive(.agy)
        await f.seedAgy("a")
        guard case .switched = await f.switcher().switchTo(target) else { Issue.record("switch failed"); return }
        #expect(!FileManager.default.fileExists(atPath: f.agyFolder.appending(path: "settings.json").path))
        #expect((try FileManager.default.attributesOfItem(atPath: f.agyFolder.path))[.posixPermissions] as? Int == 0o700)
    }

    // MARK: F03-AC-3.c10

    @Test(arguments: [SwitchStep.writeClaudeKeychain, .writeClaudeConfig, .verify])
    func `REQ/F03-AC-3.c10 a failed Claude step restores every live store and keeps the sync-back`(step: SwitchStep) async throws {
        let f = try Fixture()
        try await f.seedClaude("b")
        let target = try await f.saveLive(.claude)
        try await f.seedClaude("a", mcp: "test-mcp-live")
        let outgoing = try await f.saveLive(.claude)
        let itemBefore = await f.claudeKeychain(), configBefore = try Data(contentsOf: f.configURL)
        let outcome = await f.switcher(faults: SwitchFaults(failAt: step)).switchTo(target)
        #expect(outcome == .failed("Switch failed — Claude Code still uses a@example.com"))
        #expect(await f.claudeKeychain() == itemBefore)
        #expect(try Data(contentsOf: f.configURL) == configBefore)
        guard case .valid(let entry) = await f.vault.entry(.claude, id: outgoing.id) else { Issue.record("no entry"); return }
        #expect(entry.origin == .syncBack && entry.generation == 2)
        #expect(f.lockURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(f.box.violations.isEmpty)
    }

    @Test(arguments: [SwitchStep.writeCodexAuth, .verify])
    func `REQ/F03-AC-3.c10 a failed Codex step restores auth.json`(step: SwitchStep) async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let target = try await f.saveLive(.codex)
        try f.seedCodex("a")
        let outcome = await f.switcher(faults: SwitchFaults(failAt: step)).switchTo(target)
        #expect(outcome == .failed("Switch failed — Codex still uses a@example.com"))
        #expect(try Data(contentsOf: f.authURL) == utf8(codexAuth("a")))
        guard case .valid(let kept) = await f.vault.entries(.codex).first(where: { $0.id != target.id }) else { Issue.record("no kept entry"); return }
        #expect(kept.kept)
    }

    @Test(arguments: [SwitchStep.writeAgyKeychain, .writeAgyTokenFile, .writeAgySettings, .verify])
    func `REQ/F03-AC-3.c10 a failed agy step restores the Keychain and removes an absent-before token file`(step: SwitchStep) async throws {
        let f = try Fixture()
        await f.seedAgy("b")
        let target = try await f.saveLive(.agy)
        await f.seedAgy("a")
        let settingsText = #"{"modelProvider":"gemini","theme":"dark"}"#
        try f.box.write("home/.gemini/antigravity-cli/settings.json", settingsText)
        let outcome = await f.switcher(faults: SwitchFaults(failAt: step)).switchTo(target)
        #expect(outcome == .failed("Switch failed — Antigravity CLI still uses a@example.com"))
        #expect(await f.agyKeychain() == .found(utf8(agyValue("a"))))
        #expect(!FileManager.default.fileExists(atPath: f.agyFolder.appending(path: "antigravity-oauth-token").path))
        #expect(try Data(contentsOf: f.agyFolder.appending(path: "settings.json")) == utf8(settingsText))
        #expect(await f.vault.entries(.agy).count == 2)
        #expect(f.box.violations.isEmpty)
    }

    @Test func `REQ/F03-AC-3.c10 a failed outgoing vault write writes no live store`() async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let target = try await f.saveLive(.codex)
        try f.seedCodex("a")
        #expect(await f.switcher(faults: SwitchFaults(failAt: .syncBack)).switchTo(target) == .failed("Switch failed — Codex still uses a@example.com"))
        #expect(try Data(contentsOf: f.authURL) == utf8(codexAuth("a")))
        #expect(await f.vault.entries(.codex).count == 1)
    }

    @Test func `REQ/F03-AC-3.c10 an existing agy token file gets its old bytes back`() async throws {
        let f = try Fixture()
        await f.seedAgy("b")
        let target = try await f.saveLive(.agy)
        await f.seedAgy("a")
        try f.box.write("home/.gemini/antigravity-cli/antigravity-oauth-token", agyInner("a"))
        _ = await f.switcher(faults: SwitchFaults(failAt: .verify)).switchTo(target)
        #expect(try Data(contentsOf: f.agyFolder.appending(path: "antigravity-oauth-token")) == utf8(agyInner("a")))
    }

    // MARK: F03-AC-3.c11

    @Test func `REQ/F03-AC-3.c11 Claude Keychain bytes rewritten before verify fail the switch and restore`() async throws {
        let f = try Fixture()
        try await f.seedClaude("b")
        let target = try await f.saveLive(.claude)
        try await f.seedClaude("a")
        let itemBefore = await f.claudeKeychain(), configBefore = try Data(contentsOf: f.configURL)
        let keychain = f.box.keychain
        let faults = SwitchFaults(beforeVerify: {
            _ = await keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem("b").replacingOccurrences(of: "max", with: "pro")))
        })
        #expect(await f.switcher(faults: faults).switchTo(target) == .failed("Switch failed — Claude Code still uses a@example.com"))
        #expect(await f.claudeKeychain() == itemBefore)
        #expect(try Data(contentsOf: f.configURL) == configBefore)
    }

    @Test func `REQ/F03-AC-3.c11 an identity read back that is not the target fails the switch and restores`() async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let target = try await f.saveLive(.codex)
        try f.seedCodex("a")
        let authURL = f.authURL
        let faults = SwitchFaults(beforeVerify: { try? Data(codexAuth("c").utf8).write(to: authURL) })
        #expect(await f.switcher(faults: faults).switchTo(target) == .failed("Switch failed — Codex still uses a@example.com"))
        #expect(try Data(contentsOf: f.authURL) == utf8(codexAuth("a")))
    }

    // MARK: F03-AC-3.c13

    @Test func `REQ/F03-AC-3.c13 a switch waits for an in-flight renewal of the same tool and uses its result`() async throws {
        let f = try Fixture()
        try f.seedCodex("b")
        let target = try await f.saveLive(.codex)
        try f.seedCodex("a")
        let gate = Gate()
        let renewed = codexAuth("b").replacingOccurrences(of: "test-access-b", with: "test-access-b2")
        let vault = f.vault
        let renewal = Task {
            try await vault.exclusive(.codex) {
                await gate.wait()
                try await vault.replacePayload(.codex, id: target.id, bytes: utf8(renewed), origin: .renewal)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let switcher = f.switcher()
        let switching = Task { await switcher.switchTo(target) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: f.authURL) == utf8(codexAuth("a")))
        await gate.release()
        _ = try await renewal.value
        guard case .switched = await switching.value else { Issue.record("switch failed"); return }
        #expect(try Data(contentsOf: f.authURL) == utf8(renewed))
    }

    // MARK: F03-AC-3.c14

    @Test func `REQ/F03-AC-3.c14 a Codex switch reports a running daemon and names a running desktop app`() async throws {
        let daemon = "77 /opt/homebrew/bin/codex app-server --managed-daemon"
        let desktop = "501 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server --analytics-default-enabled"
        let cases: [([String], SwitchOutcome)] = [
            ([daemon], .switched(notice: "Codex now signs in as b@example.com.", daemonRunning: true)),
            ([desktop], .switched(notice: "Codex now signs in as b@example.com. The running Codex desktop app still uses the previous account.", daemonRunning: false)),
            ([daemon, desktop], .switched(notice: "Codex now signs in as b@example.com. The running Codex desktop app still uses the previous account.", daemonRunning: true)),
            ([], .switched(notice: "Codex now signs in as b@example.com.", daemonRunning: false)),
        ]
        for (lines, expected) in cases {
            let f = try Fixture()
            try f.seedCodex("b")
            let target = try await f.saveLive(.codex)
            try f.seedCodex("a")
            #expect(await f.switcher(lines: lines).switchTo(target) == expected)
        }
    }

    @Test func `REQ/F03-AC-3.c14 process matching for the daemon and the desktop app`() {
        let daemon = "77 /opt/homebrew/bin/codex app-server --managed-daemon"
        let daemonEq = "78 codex app-server --managed-daemon=/tmp/x"
        let desktop = "501 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server --analytics-default-enabled"
        let desktopBare = "502 /Applications/Codex.app/Contents/Resources/codex app-server"
        let others = [
            "10 codex app-server proxy", "11 codex exec-server", "12 codex app-server daemon restart",
            "13 /Users/x/.vscode/extensions/openai.chatgpt-1.0/bin/codex app-server --analytics-default-enabled",
            "14 /Applications/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService",
        ]
        #expect(CodexProcesses.daemonRunning([daemon]) && CodexProcesses.daemonRunning([daemonEq]))
        #expect(!CodexProcesses.desktopAppRunning([daemon]))
        #expect(CodexProcesses.desktopAppRunning([desktop]) && CodexProcesses.desktopAppRunning([desktopBare]))
        #expect(!CodexProcesses.daemonRunning([desktop]))
        #expect(!CodexProcesses.daemonRunning(others) && !CodexProcesses.desktopAppRunning(others))
        #expect(CodexProcesses.daemonPID(others + [desktop, daemon]) == 77)
        #expect(CodexProcesses.daemonPID(others + [desktop]) == nil)
    }

    // MARK: F03-AC-3.c15

    @Test func `REQ/F03-AC-3.c15 Claude and agy notices say when the new account takes effect`() async throws {
        let f = try Fixture()
        try await f.seedClaude("b")
        let claudeTarget = try await f.saveLive(.claude)
        try await f.seedClaude("a")
        #expect(await f.switcher().switchTo(claudeTarget) == .switched(
            notice: "Claude Code now signs in as b@example.com. New sessions use it; running ones follow within about 30 s.", daemonRunning: false))
        await f.seedAgy("b")
        let agyTarget = try await f.saveLive(.agy)
        await f.seedAgy("a")
        #expect(await f.switcher().switchTo(agyTarget) == .switched(
            notice: "Antigravity CLI now signs in as b@example.com from its next session.", daemonRunning: false))
    }

    @Test func `Restart only trusts the kernel's executable path for a daemon pid`() {
        // This test process is not named codex; a pid that does not exist resolves to nothing.
        #expect(CodexProcesses.daemonExecutable(["\(getpid()) /opt/homebrew/bin/codex app-server --managed-daemon"]) == nil)
        #expect(CodexProcesses.daemonExecutable(["999999 /tmp/evil/codex app-server --managed-daemon"]) == nil)
    }

    @Test func `the standard Claude lock timing`() {
        let t = ClaudeLockTiming.standard
        #expect(t.budget == .seconds(9) && t.poll == .milliseconds(250) && t.refreshStale == 60 && t.configStale == 10)
    }
}
