import Foundation
import Testing
import MagpieLiteCore

fileprivate let soon = Date(timeIntervalSince1970: 1_790_000_000 + 120)   // within 5 min of the rig clock's start

fileprivate func claudeTokenOK(_ tag: String) -> TestHTTPStub.Reply {
    .json(200, #"{"access_token":"test-access-\#(tag)","refresh_token":"test-refresh-\#(tag)","expires_in":3600,"scope":"user:inference user:profile"}"#)
}

fileprivate func payload(_ rig: PollerRig, _ key: AccountKey) async -> VaultEnvelope? {
    if case .valid(let e)? = await rig.vault.entry(key.tool, id: key.id) { return e }
    return nil
}

fileprivate func json(_ data: Data?) -> [String: Any]? {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

/// A Claude credential with extra keys the renewal must keep.
fileprivate func claudeWithExtras(_ tag: String, expiry: Date) -> LiveLogin {
    let base = testLogin(.claude, tag, expiry: expiry)
    let ms = Int(expiry.timeIntervalSince1970 * 1000)
    let bytes = Data(#"{"claudeAiOauth":{"accessToken":"test-access-\#(tag)","refreshToken":"test-refresh-\#(tag)","expiresAt":\#(ms),"subscriptionType":"max","rateLimitTier":"tier-x"},"mcpOAuth":{"srv":{"accessToken":"test-mcp-1"}}}"#.utf8)
    return LiveLogin(identity: base.identity, plan: base.plan, label: base.label, bytes: bytes, tokens: base.tokens,
                     clientID: nil, claudeAccount: base.claudeAccount, accountID: nil)
}

fileprivate func agyLogin(_ tag: String, client: String?, expiry: Date = soon, idToken: Bool = false) -> LiveLogin {
    let base = testLogin(.agy, tag, expiry: expiry, clientID: client)
    let stamp = ISO8601DateFormatter().string(from: expiry)
    let id = idToken ? #","id_token":"old-id-token""# : ""
    let inner = #"{"token":{"access_token":"test-access-\#(tag)","token_type":"Bearer","refresh_token":"test-refresh-\#(tag)","expiry":"\#(stamp)"},"auth_method":"consumer"\#(id)}"#
    let bytes = Data(("go-keyring-base64:" + Data(inner.utf8).base64EncodedString()).utf8)
    return LiveLogin(identity: base.identity, plan: nil, label: base.label, bytes: bytes, tokens: base.tokens,
                     clientID: client, claudeAccount: nil, accountID: nil)
}

/// Decodes an agy envelope payload.
fileprivate func agyInner(_ envelope: VaultEnvelope?) -> [String: Any]? {
    guard let text = envelope?.payloadBytes.map({ String(decoding: $0, as: UTF8.self) }), text.hasPrefix("go-keyring-base64:") else { return nil }
    return json(Data(base64Encoded: String(text.dropFirst("go-keyring-base64:".count))))
}

@MainActor @Suite struct RenewalTests {
    // MARK: F04-AC-4.c7

    @Test func `REQ/F04-AC-4.c7 a saved token expiring within 5 min is renewed, merged with unknown keys kept, then fetched`() async throws {
        let rig = try PollerRig(renewing: true) { request in
            if isTokenRequest(request) { return claudeTokenOK("b2") }
            return okReply(request)
        }
        let key = try await rig.save(claudeWithExtras("b", expiry: soon))
        await rig.poller.runBatch()
        let token = try #require(rig.tokenRequests.first)
        #expect(token.method == "POST")
        #expect(token.url.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(token.header("Content-Type") == "application/json")
        #expect(json(token.body) as NSDictionary? == ["grant_type": "refresh_token", "refresh_token": "test-refresh-b", "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
        #expect(rig.stub.requests.map { isTokenRequest($0) ? "token" : requestTag($0) ?? "?" } == ["token", "b2"])
        let saved = try #require(await payload(rig, key))
        #expect(saved.origin == .renewal && saved.generation == 2)
        let item = try #require(json(saved.payloadBytes))
        let oauth = try #require(item["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "test-access-b2")
        #expect(oauth["refreshToken"] as? String == "test-refresh-b2")
        #expect((oauth["expiresAt"] as? NSNumber)?.int64Value == Int64((rig.clock.now.timeIntervalSince1970 + 3600) * 1000))
        #expect(oauth["scopes"] as? [String] == ["user:inference", "user:profile"])
        #expect(oauth["subscriptionType"] as? String == "max" && oauth["rateLimitTier"] as? String == "tier-x")
        #expect(((item["mcpOAuth"] as? [String: Any])?["srv"] as? [String: Any])?["accessToken"] as? String == "test-mcp-1")
        #expect(rig.state.status[key]?.reading != nil)
    }

    @Test func `REQ/F04-AC-4.c7 a 401 renews then fetches once more with the new token`() async throws {
        let rig = try PollerRig(renewing: true) { request in
            if isTokenRequest(request) {
                return .json(200, #"{"access_token":"test-access-e2","refresh_token":"test-refresh-e2","id_token":"new-id"}"#)
            }
            return requestTag(request) == "e" ? .json(401, "{}") : okReply(request)
        }
        let key = try await rig.save(testLogin(.codex, "e"))
        await rig.poller.runBatch()
        #expect(rig.stub.requests.map { isTokenRequest($0) ? "token" : requestTag($0) ?? "?" } == ["e", "token", "e2"])
        let token = try #require(rig.tokenRequests.first)
        #expect(token.url.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(json(token.body) as NSDictionary? == ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token",
                                                      "refresh_token": "test-refresh-e", "scope": "openid profile email"])
        #expect(rig.stub.requests.last?.header("Authorization") == "Bearer test-access-e2")
        let auth = try #require(json(await payload(rig, key)?.payloadBytes))
        let tokens = try #require(auth["tokens"] as? [String: Any])
        #expect(tokens["access_token"] as? String == "test-access-e2" && tokens["refresh_token"] as? String == "test-refresh-e2")
        #expect(tokens["id_token"] as? String == "new-id")
        #expect((auth["last_refresh"] as? String)?.contains(".") == true)
        #expect(auth["auth_mode"] as? String == "chatgpt")
        #expect(rig.state.status[key]?.stale == false)
    }

    @Test func `REQ/F04-AC-4.c7 renewal is skipped for an unreadable or incomplete live login, a live entry, a gone entry and a replaced token`() async throws {
        let rig = try PollerRig(renewing: true) { _ in claudeTokenOK("x") }
        let renewer = try #require(rig.renewer)
        let b = testLogin(.claude, "b", expiry: soon)
        let key = try await rig.save(b)
        let trigger = RenewalTrigger.nearExpiry(accessToken: "test-access-b")
        rig.tools[.claude]!.script([.unknown("timed out")])
        #expect(await renewer.renew(key, trigger: trigger, vault: rig.vault) == .skipped("live login unreadable"))
        rig.tools[.claude]!.script([.unsupported("x")])
        guard case .skipped = await renewer.renew(key, trigger: trigger, vault: rig.vault) else { Issue.record("unsupported renewed"); return }
        rig.tools[.claude]!.script([.signedIn(testLogin(.claude, "z", complete: false))])
        guard case .skipped = await renewer.renew(key, trigger: trigger, vault: rig.vault) else { Issue.record("incomplete renewed"); return }
        rig.tools[.claude]!.script([.signedIn(b)])
        #expect(await renewer.renew(key, trigger: trigger, vault: rig.vault) == .skipped("live account"))
        rig.tools[.claude]!.script([.notSignedIn])
        guard case .skipped = await renewer.renew(key, trigger: .nearExpiry(accessToken: "test-access-old"), vault: rig.vault) else {
            Issue.record("replaced token renewed"); return
        }
        guard case .skipped = await renewer.renew(AccountKey(tool: .claude, id: "gone"), trigger: trigger, vault: rig.vault) else {
            Issue.record("gone renewed"); return
        }
        let incomplete = try await rig.save(testLogin(.claude, "c", complete: false, expiry: soon), allowIncomplete: true)
        guard case .skipped = await renewer.renew(incomplete, trigger: .nearExpiry(accessToken: "test-access-c"), vault: rig.vault) else {
            Issue.record("incomplete entry renewed"); return
        }
        #expect(rig.tokenRequests.isEmpty)
        #expect(await renewer.renew(key, trigger: trigger, vault: rig.vault) == .renewed)
        #expect(rig.tokenRequests.count == 1)
    }

    @Test func `REQ/F04-AC-4.c7 the live account is never renewed`() async throws {
        let live = testLogin(.claude, "a", expiry: soon)
        let rig = try PollerRig(live: [.claude: [.signedIn(live)]], renewing: true) { request in
            isTokenRequest(request) ? claudeTokenOK("x") : okReply(request)
        }
        try await rig.save(live)
        await rig.poller.runBatch()
        rig.clock.advance(60)
        await rig.poller.refresh(testKey(live))
        #expect(rig.tokenRequests.isEmpty)
        #expect(rig.tags == ["a", "a"])
    }

    // MARK: F04-AC-4.c8

    @Test func `REQ/F04-AC-4.c8 a sent renewal completes and persists even when its caller is cancelled`() async throws {
        let gate = TestGate()
        let rig = try PollerRig(renewing: true) { request in
            await gate.wait()
            return claudeTokenOK("b2")
        }
        let renewer = try #require(rig.renewer)
        let key = try await rig.save(testLogin(.claude, "b", expiry: soon))
        let vault = rig.vault
        let caller = Task { await renewer.renew(key, trigger: .nearExpiry(accessToken: "test-access-b"), vault: vault) }
        #expect(await eventually { rig.tokenRequests.count == 1 })
        caller.cancel()
        await gate.release()
        #expect(await caller.value == .renewed)
        #expect(await payload(rig, key)?.generation == 2)
        #expect(tokenSet(.claude, bytes: try #require(await payload(rig, key)?.payloadBytes))?.accessToken == "test-access-b2")
    }

    @Test func `REQ/F04-AC-4.c8 stopping the poller mid-renewal still persists the result`() async throws {
        let gate = TestGate()
        let rig = try PollerRig(renewing: true) { request in
            if isTokenRequest(request) { await gate.wait(); return claudeTokenOK("b2") }
            return okReply(request)
        }
        let key = try await rig.save(testLogin(.claude, "b", expiry: soon))
        rig.poller.start()
        #expect(await eventually { rig.tokenRequests.count == 1 })
        rig.poller.stop()
        await gate.release()
        var generation = 0
        for _ in 0..<100 {
            if let e = await payload(rig, key), e.generation == 2 { generation = 2; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(generation == 2)
    }

    // MARK: F04-AC-4.c9

    @Test(arguments: [
        (Tool.claude, TestHTTPStub.Reply.json(400, #"{"error":"invalid_grant"}"#)),
        (Tool.claude, .json(403, #"{"error":"invalid_grant","error_description":"revoked"}"#)),
        (Tool.codex, .json(400, "{}")), (Tool.codex, .json(401, "not json")),
        (Tool.agy, .json(400, #"{"error":"invalid_grant"}"#)),
    ])
    func `REQ/F04-AC-4.c9 a refused renewal marks needs sign-in, leaves the vault file alone and stops polling it`(tool: Tool, refusal: TestHTTPStub.Reply) async throws {
        let rig = try PollerRig(renewing: true) { request in isTokenRequest(request) ? refusal : okReply(request) }
        let login = tool == .agy ? agyLogin("b", client: OAuthClients.antigravityClientID) : testLogin(tool, "b", expiry: soon)
        let key = try await rig.save(login)
        let file = rig.box.supportRoot.appending(path: "vault/\(tool.rawValue)/\(key.id).json")
        let before = try Data(contentsOf: file)
        await rig.poller.runBatch()
        #expect(rig.state.status[key]?.flag == .needsSignIn)
        #expect(rig.state.snapshot(tool).accounts.first?.flag == .needsSignIn)
        #expect(try Data(contentsOf: file) == before)
        let sent = rig.stub.requests.count
        rig.clock.advance(600)
        await rig.poller.runBatch()
        await rig.poller.refresh(key)
        #expect(rig.stub.requests.count == sent)
    }

    // MARK: F04-AC-4.c10

    @Test(arguments: [
        (Tool.codex, TestHTTPStub.Reply.json(403, "{}")),
        (Tool.claude, .json(401, #"{"error":"invalid_client"}"#)),
        (Tool.claude, .json(503, "busy")),
        (Tool.agy, .json(500, "{}")),
        (Tool.codex, .fail(.notConnectedToInternet)),
        (Tool.claude, .json(200, "not json")),
    ])
    func `REQ/F04-AC-4.c10 a transient renewal failure leaves the vault alone, marks stale and retries next cycle`(tool: Tool, failure: TestHTTPStub.Reply) async throws {
        let rig = try PollerRig(renewing: true) { request in isTokenRequest(request) ? failure : okReply(request) }
        let login = tool == .agy ? agyLogin("b", client: OAuthClients.antigravityClientID) : testLogin(tool, "b", expiry: soon)
        let key = try await rig.save(login)
        let file = rig.box.supportRoot.appending(path: "vault/\(tool.rawValue)/\(key.id).json")
        let before = try Data(contentsOf: file)
        await rig.poller.runBatch()
        #expect(try Data(contentsOf: file) == before)
        #expect(rig.state.status[key]?.stale == true)
        #expect(rig.state.status[key]?.flag == .ok)
        #expect(rig.tokenRequests.count == 1)
        rig.clock.advance(300)
        await rig.poller.runBatch()
        #expect(rig.tokenRequests.count == 2)
    }

    @Test func `a renewal that times out is transient`() async throws {
        let stub = TestHTTPStub { _ in .never }
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let login = testLogin(.codex, "b", expiry: soon)
        try await vault.save(.signedIn(login))
        let renewer = Renewer(http: HTTPClient(session: stub.session, timeout: 0.2), tools: [FakeTool(.codex, [.notSignedIn])], now: { Date() })
        #expect(await renewer.renew(testKey(login), trigger: .nearExpiry(accessToken: login.tokens.accessToken!), vault: vault) == .transient("timed out"))
    }

    // MARK: F04-AC-4.c11

    @Test func `REQ/F04-AC-4.c11 Google invalid_client marks every account of that client and blocks it until relaunch`() async throws {
        let live = agyLogin("a", client: OAuthClients.antigravityClientID, expiry: Date(timeIntervalSince1970: 4_000_000_000))
        let rig = try PollerRig(live: [.agy: [.signedIn(live)]], renewing: true) { request in
            if isTokenRequest(request) { return .json(401, #"{"error":{"status":"invalid_client","message":"The OAuth client was deleted."}}"#) }
            return okReply(request)
        }
        try await rig.save(live)
        let b = try await rig.save(agyLogin("b", client: OAuthClients.antigravityClientID))
        let c = try await rig.save(agyLogin("c", client: OAuthClients.antigravityClientID))
        await rig.poller.runBatch()
        #expect(rig.tokenRequests.count == 1)
        for key in [b, c, testKey(live)] { #expect(rig.state.status[key]?.flag == .appNeedsUpdate) }
        #expect(await rig.renewer!.isBlocked(clientID: OAuthClients.antigravityClientID))
        #expect(rig.state.snapshot(.agy).accounts.allSatisfy { $0.flag != .needsSignIn })
        let liveFetches = rig.count("a")
        rig.clock.advance(600)
        await rig.poller.runBatch()
        await rig.poller.refresh(b)
        #expect(rig.tokenRequests.count == 1)
        #expect(rig.count("a") > liveFetches)
        #expect(await rig.renewer!.renew(c, trigger: .nearExpiry(accessToken: "test-access-c"), vault: rig.vault) == .appNeedsUpdate)
        #expect(rig.tokenRequests.count == 1)
    }

    @Test func `REQ/F04-AC-4.c11 a saved agy login without an embedded client needs an app update and sends nothing`() async throws {
        let rig = try PollerRig(renewing: true) { request in isTokenRequest(request) ? .json(200, "{}") : okReply(request) }
        let none = try await rig.save(agyLogin("b", client: nil))
        let other = try await rig.save(agyLogin("c", client: "other-client.apps.googleusercontent.com"))
        await rig.poller.runBatch()
        #expect(rig.tokenRequests.isEmpty)
        #expect(rig.state.status[none]?.flag == .appNeedsUpdate)
        #expect(rig.state.status[other]?.flag == .appNeedsUpdate)
    }

    // MARK: F04-AC-4.c12

    @Test func `REQ/F04-AC-4.c12 a Google reply's refresh token replaces the stored one in the same persist`() async throws {
        let rig = try PollerRig(renewing: true) { request in
            if isTokenRequest(request) {
                return .json(200, #"{"access_token":"test-access-b2","expires_in":3599,"refresh_token":"test-refresh-b2","id_token":"new-id-token","token_type":"Bearer"}"#)
            }
            return okReply(request)
        }
        let key = try await rig.save(agyLogin("b", client: OAuthClients.antigravityClientID, idToken: true))
        await rig.poller.runBatch()
        let request = try #require(rig.tokenRequests.first)
        #expect(request.url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.header("Accept") == "application/json")
        let form = Dictionary(uniqueKeysWithValues: String(decoding: request.body, as: UTF8.self).split(separator: "&").map {
            let kv = $0.split(separator: "=", maxSplits: 1)
            return (String(kv[0]), String(kv[1]).removingPercentEncoding ?? "")
        })
        #expect(form["grant_type"] == "refresh_token" && form["refresh_token"] == "test-refresh-b")
        #expect(form["client_id"] == OAuthClients.antigravityClientID)
        #expect(form["client_secret"] == OAuthClients.antigravitySecret(forClientID: OAuthClients.antigravityClientID))
        let saved = try #require(await payload(rig, key))
        #expect(saved.generation == 2)
        let inner = try #require(agyInner(saved))
        let token = try #require(inner["token"] as? [String: Any])
        #expect(token["access_token"] as? String == "test-access-b2")
        #expect(token["refresh_token"] as? String == "test-refresh-b2")
        #expect(token["expiry"] as? String == ISO8601DateFormatter().string(from: rig.clock.now.addingTimeInterval(3599)))
        #expect(inner["id_token"] as? String == "new-id-token")
        #expect(inner["auth_method"] as? String == "consumer")
    }

    @Test func `a Google reply without a refresh token keeps the stored one`() async throws {
        let rig = try PollerRig(renewing: true) { request in
            isTokenRequest(request) ? .json(200, #"{"access_token":"test-access-b2","expires_in":3599}"#) : okReply(request)
        }
        let key = try await rig.save(agyLogin("b", client: OAuthClients.antigravityClientID))
        await rig.poller.runBatch()
        let token = try #require(agyInner(await payload(rig, key))?["token"] as? [String: Any])
        #expect(token["refresh_token"] as? String == "test-refresh-b")
    }

    // MARK: F04-AC-4.c20

    @Test func `REQ/F04-AC-4.c20 a row refresh renews first when due and fetches only that account`() async throws {
        let rig = try PollerRig(renewing: true) { request in isTokenRequest(request) ? claudeTokenOK("b2") : okReply(request) }
        let b = try await rig.save(testLogin(.claude, "b", expiry: soon))
        try await rig.save(testLogin(.claude, "c"))
        await rig.poller.refresh(b)
        #expect(rig.stub.requests.map { isTokenRequest($0) ? "token" : requestTag($0) ?? "?" } == ["token", "b2"])
        #expect(rig.sleeper.durations.isEmpty)
    }

    @Test func `REQ/F04-AC-4.c20 a row refresh does nothing for needs sign-in, app needs update, incomplete and unreadable rows`() async throws {
        let rig = try PollerRig(renewing: true) { request in
            if isTokenRequest(request) { return request.url.host == "oauth2.googleapis.com" ? .json(400, #"{"error":"invalid_client"}"#) : .json(400, #"{"error":"invalid_grant"}"#) }
            return okReply(request)
        }
        let refused = try await rig.save(testLogin(.claude, "b", expiry: soon))
        let agy = try await rig.save(agyLogin("g", client: OAuthClients.antigravityClientID))
        let incomplete = try await rig.save(testLogin(.codex, "c", complete: false), allowIncomplete: true)
        let unreadable = AccountKey(tool: .codex, id: String(repeating: "f", count: 64))
        try rig.box.write("support/vault/codex/\(unreadable.id).json", "{}")
        await rig.poller.runBatch()
        #expect(rig.state.status[refused]?.flag == .needsSignIn && rig.state.status[agy]?.flag == .appNeedsUpdate)
        let sent = rig.stub.requests.count
        for key in [refused, agy, incomplete, unreadable] { await rig.poller.refresh(key) }
        #expect(rig.stub.requests.count == sent)
    }

    @Test func `REQ/F04-AC-4.c20 a live row refresh reads the live login`() async throws {
        let a = testLogin(.codex, "a")
        let rig = try PollerRig(live: [.codex: [.signedIn(a)]], renewing: true)
        await rig.poller.runBatch()
        let reads = rig.tools[.codex]!.reads
        rig.clock.advance(120)
        await rig.poller.refresh(testKey(a))
        #expect(rig.tools[.codex]!.reads == reads + 1)
        #expect(rig.tags == ["a", "a"])
    }

    // MARK: F04-AC-4.c22

    @Test func `REQ/F04-AC-4.c22 saving new live bytes clears needs sign-in and the account is polled again`() async throws {
        let replies = TokenReplies([.json(400, #"{"error":"invalid_grant"}"#)])
        let rig = try PollerRig(renewing: true) { request in isTokenRequest(request) ? replies.next() : okReply(request) }
        let key = try await rig.save(testLogin(.claude, "b", expiry: soon))
        await rig.poller.runBatch()
        #expect(rig.state.status[key]?.flag == .needsSignIn)
        try await rig.save(testLogin(.claude, "b"))
        await rig.poller.reloadVault()
        #expect(rig.state.status[key]?.flag == .ok)
        #expect(rig.state.snapshot(.claude).accounts.first?.flag == .ok)
        rig.clock.advance(300)
        await rig.poller.runBatch()
        #expect(rig.count("b") == 1)
    }

    @Test func `REQ/F04-AC-4.c22 app needs update clears only for an embedded client that has not drawn invalid_client`() async throws {
        let rig = try PollerRig(renewing: true) { request in
            isTokenRequest(request) ? .json(400, #"{"error":"invalid_client"}"#) : okReply(request)
        }
        let noClient = try await rig.save(agyLogin("n", client: nil))
        await rig.poller.runBatch()
        #expect(rig.state.status[noClient]?.flag == .appNeedsUpdate)
        try await rig.save(agyLogin("n", client: nil, expiry: Date(timeIntervalSince1970: 4_000_000_000)))
        await rig.poller.reloadVault()
        #expect(rig.state.status[noClient]?.flag == .appNeedsUpdate)

        let blocked = try await rig.save(agyLogin("k", client: OAuthClients.antigravityClientID))
        await rig.poller.runBatch()
        #expect(rig.state.status[blocked]?.flag == .appNeedsUpdate)
        try await rig.save(agyLogin("k", client: OAuthClients.antigravityClientID, expiry: Date(timeIntervalSince1970: 4_000_000_000)))
        await rig.poller.reloadVault()
        #expect(rig.state.status[blocked]?.flag == .appNeedsUpdate)

        let fresh = try PollerRig(renewing: true)
        let key = try await fresh.save(agyLogin("m", client: nil))
        await fresh.poller.runBatch()
        #expect(fresh.state.status[key]?.flag == .appNeedsUpdate)
        try await fresh.save(agyLogin("m", client: OAuthClients.antigravityClientID, expiry: Date(timeIntervalSince1970: 4_000_000_000)))
        await fresh.poller.reloadVault()
        #expect(fresh.state.status[key]?.flag == .ok)
    }
}

/// Token-endpoint replies in order; the last one repeats.
fileprivate final class TokenReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [TestHTTPStub.Reply]
    init(_ replies: [TestHTTPStub.Reply]) { self.replies = replies }
    func next() -> TestHTTPStub.Reply { lock.withLock { replies.count > 1 ? replies.removeFirst() : replies[0] } }
}
