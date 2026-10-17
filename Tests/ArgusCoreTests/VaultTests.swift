import Foundation
import Testing
import ArgusCore

fileprivate let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

fileprivate func login(_ tool: Tool, email: String = "alice@example.com", scope: String? = "scope-1", subject: String? = "sub-1",
                       bytes: String = "test-credential-1", refresh: String = "test-refresh-1", clientID: String? = nil,
                       claudeAccount: String? = nil) -> LiveLogin {
    let identity: Identity = switch tool {
    case .claude: .claude(email: email, organizationUuid: scope, refreshToken: refresh)
    case .codex: .codex(email: email, accountID: scope, refreshToken: refresh)
    case .agy: .agy(subject: subject, email: email, refreshToken: refresh)
    }
    return LiveLogin(identity: identity, plan: tool == .agy ? nil : "pro", label: email, bytes: utf8(bytes),
                     tokens: TokenSet(accessToken: "test-access-1", accessTokenExpiry: nil, refreshToken: refresh),
                     clientID: clientID, claudeAccount: claudeAccount.map(utf8), accountID: tool == .codex ? scope : nil)
}

fileprivate func files(_ box: TestSandbox, _ tool: Tool) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: box.supportRoot.appending(path: "vault/\(tool.rawValue)").path)) ?? []).sorted()
}

fileprivate func fileURL(_ box: TestSandbox, _ tool: Tool, _ id: String) -> URL {
    box.supportRoot.appending(path: "vault/\(tool.rawValue)/\(id).json")
}

fileprivate func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

/// Opens once; every waiter resumes then.
fileprivate actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

fileprivate actor Log {
    private(set) var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

@Suite struct VaultTests {
    // MARK: F02-AC-2.c1

    @Test func `REQ/F02-AC-2.c1 save writes a new envelope with the exact live bytes and identity snapshot`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot, now: { fixedNow })
        let live = login(.claude, bytes: "{\"claudeAiOauth\":{\"accessToken\":\"test-access-1\"}}\n", claudeAccount: #"{"emailAddress":"alice@example.com"}"#)
        let envelope = try await vault.save(.signedIn(live))
        #expect(envelope.v == 1)
        #expect(envelope.tool == .claude)
        #expect(envelope.identity == live.identity)
        #expect(envelope.identityKey == live.identity.key)
        #expect(envelope.payload == live.bytes.base64EncodedString())
        #expect(envelope.payloadBytes == live.bytes)
        #expect(envelope.label == "alice@example.com")
        #expect(envelope.plan == "pro")
        #expect(envelope.claudeAccount == #"{"emailAddress":"alice@example.com"}"#)
        #expect(envelope.generation == 1)
        #expect(envelope.capturedAt == fixedNow)
        #expect(envelope.origin == .save)
        #expect(!envelope.kept)
        let url = fileURL(box, .claude, live.identity.fileID)
        #expect(mode(url) == 0o600)
        #expect(files(box, .claude) == ["\(live.identity.fileID).json"])
        #expect(await vault.entries(.claude) == [.valid(envelope)])
        #expect(await vault.entry(.claude, id: live.identity.fileID) == .valid(envelope))
    }

    // MARK: F02-AC-2.c2

    @Test func `REQ/F02-AC-2.c2 saving an identity again replaces its file, clears kept and clones the old file to prev`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot, now: { fixedNow })
        let first = login(.codex, bytes: "test-credential-1")
        try await vault.save(.signedIn(first), origin: .kept)
        let id = first.identity.fileID
        let before = try Data(contentsOf: fileURL(box, .codex, id))
        let second = login(.codex, bytes: "test-credential-2", refresh: "test-refresh-2")
        let envelope = try await vault.save(.signedIn(second))
        #expect(!envelope.kept)
        #expect(envelope.generation == 2)
        #expect(envelope.payloadBytes == utf8("test-credential-2"))
        #expect(try Data(contentsOf: fileURL(box, .codex, id).appendingPathExtension("prev")) == before)
        #expect(await vault.entries(.codex).count == 1)
        #expect(files(box, .codex) == ["\(id).json", "\(id).json.prev"])
    }

    @Test func `REQ/F02-AC-2.c2 sync-back, renewal and undo keep the kept flag while kept sets it`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let live = login(.agy)
        #expect(try await vault.save(.signedIn(live), origin: .kept).kept)
        #expect(try await vault.save(.signedIn(live), origin: .syncBack).kept)
        #expect(try await vault.replacePayload(.agy, id: live.identity.fileID, bytes: utf8("test-credential-3"), origin: .renewal).kept)
        #expect(!(try await vault.save(.signedIn(live), origin: .save).kept))
        #expect(!(try await vault.save(.signedIn(login(.agy, subject: "sub-new")), origin: .syncBack).kept))
    }

    @Test func `replacePayload keeps metadata, bumps the generation and refuses a missing id`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot, now: { fixedNow })
        let live = login(.agy, clientID: "client-1")
        let saved = try await vault.save(.signedIn(live))
        let renewed = try await vault.replacePayload(.agy, id: live.identity.fileID, bytes: utf8("test-credential-9"), origin: .renewal)
        #expect(renewed.generation == saved.generation + 1)
        #expect(renewed.origin == .renewal)
        #expect(renewed.payloadBytes == utf8("test-credential-9"))
        #expect(renewed.identity == saved.identity && renewed.label == saved.label && renewed.clientId == "client-1")
        await #expect(throws: VaultError.self) {
            try await vault.replacePayload(.agy, id: String(repeating: "0", count: 64), bytes: Data(), origin: .renewal)
        }
    }

    // MARK: F02-AC-2.c3

    @Test func `REQ/F02-AC-2.c3 two Codex logins sharing an email but not an account id are two files and removing one keeps the other`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let personal = login(.codex, email: "bob@example.com", scope: "acct-personal", bytes: "test-credential-p")
        let team = login(.codex, email: "bob@example.com", scope: "acct-team", bytes: "test-credential-t")
        try await vault.save(.signedIn(personal))
        try await vault.save(.signedIn(team))
        #expect(await vault.entries(.codex).count == 2)
        let teamBytes = try Data(contentsOf: fileURL(box, .codex, team.identity.fileID))
        _ = try await vault.remove(.codex, id: personal.identity.fileID)
        #expect(await vault.entries(.codex).map(\.id) == [team.identity.fileID])
        #expect(try Data(contentsOf: fileURL(box, .codex, team.identity.fileID)) == teamBytes)
    }

    // MARK: F02-AC-2.c4

    @Test func `REQ/F02-AC-2.c4 Save is refused with the reason for wiped, absent, unreadable, unsupported and incomplete logins`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let saved = login(.claude)
        try await vault.save(.signedIn(saved))
        let snapshot = try Data(contentsOf: fileURL(box, .claude, saved.identity.fileID))
        let incomplete = login(.claude, scope: nil, bytes: "test-credential-x")
        let cases: [(LiveState, String)] = [
            (.wiped, "signed out"), (.notSignedIn, "not signed in"), (.unknown("timed out"), "can't be read"),
            (.unsupported("keyring"), "unsupported storage mode"), (.signedIn(incomplete), "incomplete identity"),
        ]
        for (state, reason) in cases {
            await #expect(throws: VaultError(reason)) { try await vault.save(state) }
        }
        #expect(files(box, .claude) == ["\(saved.identity.fileID).json"])
        #expect(try Data(contentsOf: fileURL(box, .claude, saved.identity.fileID)) == snapshot)
    }

    @Test func `an incomplete identity is saved only when allowed`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let incomplete = login(.claude, scope: nil)
        let envelope = try await vault.save(.signedIn(incomplete), origin: .kept, allowIncomplete: true)
        #expect(envelope.identityKey.hasPrefix("claude:incomplete:"))
        #expect(await vault.entries(.claude).count == 1)
    }

    // MARK: F02-AC-2.c5

    @Test func `REQ/F02-AC-2.c5 a write failing after the staged file leaves the target byte-identical and lists no stray`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let live = login(.agy)
        try await vault.save(.signedIn(live))
        let id = live.identity.fileID
        let before = try Data(contentsOf: fileURL(box, .agy, id))
        let faulty = try Vault(supportRoot: box.supportRoot, faults: VaultFaults(failAfterStagedWrite: true))
        await #expect(throws: VaultError.self) { try await faulty.save(.signedIn(login(.agy, bytes: "test-credential-2"))) }
        #expect(try Data(contentsOf: fileURL(box, .agy, id)) == before)
        #expect(files(box, .agy).contains { $0.hasSuffix(".tmp") })
        #expect(await vault.entries(.agy).map(\.id) == [id])
        guard case .valid(let current) = await vault.entry(.agy, id: id) else { Issue.record("entry not valid"); return }
        #expect(current.payloadBytes == utf8("test-credential-1"))
    }

    @Test func `REQ/F02-AC-2.c5 launch promotes a newer complete staged file and deletes other strays`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let live = login(.agy)
        try await vault.save(.signedIn(live))
        let faulty = try Vault(supportRoot: box.supportRoot, faults: VaultFaults(failAfterStagedWrite: true))
        _ = try? await faulty.save(.signedIn(login(.agy, bytes: "test-credential-2")))
        try box.write("support/vault/agy/\(live.identity.fileID).json.garbage.tmp", "{")
        let relaunched = try Vault(supportRoot: box.supportRoot)
        #expect(!files(box, .agy).contains { $0.hasSuffix(".tmp") })
        guard case .valid(let current) = await relaunched.entry(.agy, id: live.identity.fileID) else { Issue.record("not valid"); return }
        #expect(current.generation == 2)
        #expect(current.payloadBytes == utf8("test-credential-2"))
    }

    // MARK: F02-AC-2.c6

    @Test func `REQ/F02-AC-2.c6 the vault folder exists with mode 0700 and is excluded from backup`() throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        _ = try Vault(supportRoot: box.supportRoot)
        let vaultURL = box.supportRoot.appending(path: "vault", directoryHint: .isDirectory)
        #expect(mode(vaultURL) == 0o700)
        for tool in Tool.allCases { #expect(mode(vaultURL.appending(path: tool.rawValue)) == 0o700) }
        #expect(try vaultURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func `REQ/F02-AC-2.c6 launch tightens an existing vault folder to 0700`() throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vaultURL = box.supportRoot.appending(path: "vault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try Vault(supportRoot: box.supportRoot)
        #expect(mode(vaultURL) == 0o700)
    }

    // MARK: F02-AC-2.c7

    @Test func `REQ/F02-AC-2.c7 a file failing validation is an unreadable entry and no write targets it`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let live = login(.claude)
        let id = live.identity.fileID
        try box.write("support/vault/claude/\(id).json", "{\"v\":1,\"broken\":true}")
        let before = try Data(contentsOf: fileURL(box, .claude, id))
        guard case .unreadable(let tool, let entryID, _) = await vault.entries(.claude).first else { Issue.record("not unreadable"); return }
        #expect(tool == .claude && entryID == id)
        await #expect(throws: VaultError("unreadable vault entry")) { try await vault.save(.signedIn(live)) }
        await #expect(throws: VaultError.self) { try await vault.replacePayload(.claude, id: id, bytes: utf8("x"), origin: .renewal) }
        #expect(try Data(contentsOf: fileURL(box, .claude, id)) == before)
    }

    @Test func `REQ/F02-AC-2.c7 version, tool, file name and payload mismatches are unreadable`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let live = login(.codex)
        let saved = try await vault.save(.signedIn(live))
        let good = try String(contentsOf: fileURL(box, .codex, live.identity.fileID), encoding: .utf8)
        let other = String(repeating: "a", count: 64)
        try box.write("support/vault/codex/\(other).json", good)
        try box.write("support/vault/claude/\(live.identity.fileID).json", good)
        let badPayload = good.replacingOccurrences(of: saved.payload, with: "%%%")
        let badVersion = good.replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
        try box.write("support/vault/agy/\(live.identity.fileID).json", good)
        let entries = await vault.entries(.codex)
        #expect(entries.count == 2)
        #expect(entries.contains { if case .unreadable(_, let id, _) = $0 { id == other } else { false } })
        guard case .unreadable = await vault.entries(.claude).first, case .unreadable = await vault.entries(.agy).first else {
            Issue.record("tool mismatch not unreadable"); return
        }
        for text in [badPayload, badVersion] {
            try box.write("support/vault/codex/\(live.identity.fileID).json", text)
            guard case .unreadable = await vault.entry(.codex, id: live.identity.fileID) else { Issue.record("accepted \(text.prefix(20))"); continue }
        }
    }

    // MARK: F02-AC-2.c8

    @Test func `REQ/F02-AC-2.c8 a second instance can't take the vault lock while the first holds it`() throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        var first: InstanceLock? = InstanceLock.acquire(supportRoot: box.supportRoot)
        #expect(first != nil)
        #expect(InstanceLock.acquire(supportRoot: box.supportRoot) == nil)
        #expect(FileManager.default.fileExists(atPath: box.supportRoot.appending(path: "vault/.lock").path))
        first = nil
        #expect(InstanceLock.acquire(supportRoot: box.supportRoot) != nil)
        _ = first
    }

    // MARK: F02-AC-2.c9

    @Test func `REQ/F02-AC-2.c9 an agy login saves its id_token azp as clientId`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let envelope = try await vault.save(.signedIn(login(.agy, clientID: OAuthClients.antigravityClientID)))
        #expect(envelope.clientId == OAuthClients.antigravityClientID)
        guard case .valid(let read) = await vault.entries(.agy).first else { Issue.record("not saved"); return }
        #expect(read.clientId == OAuthClients.antigravityClientID)
    }

    @Test func `the Antigravity secret is embedded only for its own client`() {
        #expect(OAuthClients.antigravityClientID == "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com")
        #expect(OAuthClients.antigravitySecret(forClientID: OAuthClients.antigravityClientID) != nil)
        #expect(OAuthClients.antigravitySecret(forClientID: "other.apps.googleusercontent.com") == nil)
    }

    // MARK: F02-AC-2.c10

    @Test func `REQ/F02-AC-2.c10 no vault error carries a token or credential value`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let secrets = ["test-access-1", "test-refresh-1", "test-credential-1", utf8("test-credential-1").base64EncodedString()]
        let live = login(.claude)
        try await vault.save(.signedIn(live))
        try box.write("support/vault/codex/\(login(.codex).identity.fileID).json", "{\"payload\":\"test-credential-1\"}")
        let faulty = try Vault(supportRoot: box.supportRoot, faults: VaultFaults(failAfterStagedWrite: true))
        var errors: [VaultError] = []
        func collect(_ op: () async throws -> Void) async {
            do { try await op() } catch let e as VaultError { errors.append(e) } catch { Issue.record("unexpected \(type(of: error))") }
        }
        for state in [LiveState.wiped, .notSignedIn, .unknown("test-access-1"), .unsupported("test-refresh-1"), .signedIn(login(.claude, scope: nil))] {
            await collect { try await vault.save(state) }
        }
        await collect { try await vault.save(.signedIn(login(.codex))) }
        await collect { try await faulty.save(.signedIn(live)) }
        await collect { try await vault.replacePayload(.agy, id: "missing", bytes: utf8("test-credential-1"), origin: .renewal) }
        await collect { _ = try await vault.remove(.agy, id: "missing") }
        #expect(errors.count == 9)
        for error in errors {
            for secret in secrets { #expect(!error.description.contains(secret)) }
        }
    }

    // MARK: remove / restore

    @Test func `remove deletes the file and prev, restore writes the same bytes back once`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let live = login(.claude)
        try await vault.save(.signedIn(live))
        try await vault.save(.signedIn(live))
        let id = live.identity.fileID
        let bytes = try Data(contentsOf: fileURL(box, .claude, id))
        let removed = try await vault.remove(.claude, id: id)
        #expect(removed.bytes == bytes)
        #expect(files(box, .claude).isEmpty)
        #expect(try await vault.restore(removed))
        #expect(try Data(contentsOf: fileURL(box, .claude, id)) == bytes)
        #expect(mode(fileURL(box, .claude, id)) == 0o600)
        #expect(!(try await vault.restore(removed)))
    }

    // MARK: exclusive section (helper tests)

    @Test func `exclusive runs bodies for one tool one after another in call order`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let gate = Gate(), log = Log()
        var tasks: [Task<Void, Error>] = []
        for i in 0..<3 {
            tasks.append(Task {
                try await vault.exclusive(.claude) {
                    await log.add("start \(i)")
                    if i == 0 { await gate.wait() }
                    try await Task.sleep(for: .milliseconds(10))
                    await log.add("end \(i)")
                }
            })
            try await Task.sleep(for: .milliseconds(50))
        }
        await gate.release()
        for t in tasks { try await t.value }
        #expect(await log.items == ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2"])
    }

    @Test func `exclusive finishes a body whose caller was cancelled before the next body starts`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let log = Log()
        let caller = Task {
            try await vault.exclusive(.codex) {
                try await Task.sleep(for: .milliseconds(150))
                await log.add("first done")
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        caller.cancel()
        try await vault.exclusive(.codex) { await log.add("second") }
        #expect(await log.items == ["first done", "second"])
    }

    @Test func `exclusive bodies for different tools run independently`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let gate = Gate(), log = Log()
        let blocked = Task { try await vault.exclusive(.claude) { await gate.wait(); await log.add("claude") } }
        try await Task.sleep(for: .milliseconds(30))
        try await vault.exclusive(.agy) { await log.add("agy") }
        #expect(await log.items == ["agy"])
        await gate.release()
        try await blocked.value
        #expect(await log.items == ["agy", "claude"])
    }
}
