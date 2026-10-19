import Foundation
import ArgusCore

/// A tool adapter whose live reads return scripted states (the last one repeats).
final class FakeTool: ToolAdapter, @unchecked Sendable {
    let tool: Tool
    private let lock = NSLock()
    private var states: [LiveState]
    private var count = 0

    init(_ tool: Tool, _ states: [LiveState]) {
        self.tool = tool
        self.states = states
    }

    var reads: Int { lock.withLock { count } }
    func script(_ next: [LiveState]) { lock.withLock { states = next } }

    /// Readers for other contexts, by context id; a context without one reads this one.
    private var others: [String: FakeTool] = [:]
    func add(_ context: ToolContext, _ reader: FakeTool) { lock.withLock { others[context.id] = reader } }
    func scoped(to context: ToolContext) -> any ToolAdapter { lock.withLock { others[context.id] } ?? self }

    func readLive() async -> LiveState {
        lock.withLock {
            count += 1
            return states.count > 1 ? states.removeFirst() : states[0]
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    var closure: @Sendable () -> Date { { self.now } }
}

/// Records each requested sleep, then sleeps until cancelled.
final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var durations: [Duration] { lock.withLock { recorded } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { recorded.append(duration) }
        try await Task.sleep(for: .seconds(3600))
    }
}

/// Opens once; every waiter resumes then.
actor TestGate {
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

/// A credential for `tool` whose access token is `test-access-<tag>` (Codex: an unsigned JWT carrying the tag).
func testCredential(_ tool: Tool, _ tag: String, expiry: Date = Date(timeIntervalSince1970: 4_000_000_000)) -> (bytes: Data, tokens: TokenSet) {
    let refresh = "test-refresh-\(tag)"
    switch tool {
    case .claude:
        let access = "test-access-\(tag)"
        let ms = Int(expiry.timeIntervalSince1970 * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expiresAt":\#(ms),"subscriptionType":"max"}}"#
        return (Data(json.utf8), TokenSet(accessToken: access, accessTokenExpiry: expiry, refreshToken: refresh))
    case .codex:
        let access = testJWT(["exp": Int(expiry.timeIntervalSince1970), "tag": tag])
        let json = #"{"auth_mode":"chatgpt","tokens":{"access_token":"\#(access)","refresh_token":"\#(refresh)"}}"#
        return (Data(json.utf8), TokenSet(accessToken: access, accessTokenExpiry: expiry, refreshToken: refresh))
    case .agy:
        let access = "test-access-\(tag)"
        let stamp = ISO8601DateFormatter().string(from: expiry)
        let json = #"{"token":{"access_token":"\#(access)","token_type":"Bearer","refresh_token":"\#(refresh)","expiry":"\#(stamp)"},"auth_method":"consumer"}"#
        return (Data(json.utf8), TokenSet(accessToken: access, accessTokenExpiry: expiry, refreshToken: refresh))
    }
}

func testLogin(_ tool: Tool, _ tag: String, complete: Bool = true, expiry: Date = Date(timeIntervalSince1970: 4_000_000_000),
               clientID: String? = nil) -> LiveLogin {
    let c = testCredential(tool, tag, expiry: expiry)
    let identity: Identity = switch tool {
    case .claude: .claude(email: "\(tag)@example.com", organizationUuid: complete ? "org-\(tag)" : nil, refreshToken: c.tokens.refreshToken)
    case .codex: .codex(email: "\(tag)@example.com", accountID: complete ? "acct-\(tag)" : nil, refreshToken: c.tokens.refreshToken)
    case .agy: .agy(subject: complete ? "sub-\(tag)" : nil, email: "\(tag)@example.com", refreshToken: c.tokens.refreshToken)
    }
    return LiveLogin(identity: identity, plan: tool == .agy ? nil : "pro", label: "\(tag)@example.com", bytes: c.bytes, tokens: c.tokens,
                     clientID: clientID, claudeAccount: tool == .claude ? Data(#"{"emailAddress":"\#(tag)@example.com"}"#.utf8) : nil,
                     accountID: tool == .codex && complete ? "acct-\(tag)" : nil)
}

func testKey(_ login: LiveLogin) -> AccountKey { AccountKey(tool: login.identity.tool, id: login.identity.fileID) }

/// The tag a stub request was sent for: the bearer token's `test-access-<tag>`, or a Codex JWT's `tag` claim.
func requestTag(_ request: TestHTTPStub.Request) -> String? {
    guard let auth = request.header("Authorization"), auth.hasPrefix("Bearer ") else { return nil }
    let token = String(auth.dropFirst(7))
    if token.hasPrefix("test-access-") { return String(token.dropFirst("test-access-".count)) }
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    let claims = Data(base64Encoded: b64).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    return claims?["tag"] as? String
}

let claudeUsageOK = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null}}"#
let codexUsageOK = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1790003600},"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1790600000}}}"#
let agyQuotaOK = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.9},{"window":"weekly","remainingFraction":0.8}]}]}"#

/// A usage reply that succeeds for every vendor.
func okReply(_ request: TestHTTPStub.Request) -> TestHTTPStub.Reply {
    let url = request.url.absoluteString
    if url.hasSuffix(":loadCodeAssist") { return .json(200, #"{"cloudaicompanionProject":"proj-1"}"#) }
    if url.hasSuffix(":retrieveUserQuotaSummary") { return .json(200, agyQuotaOK) }
    if url.contains("chatgpt.com") { return .json(200, codexUsageOK) }
    return .json(200, claudeUsageOK)
}

/// Waits (≤ 1 s) until `condition` holds.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// One poller over a temp vault, fake tools and a stubbed network; `renewing` attaches a renewer on the same network.
@MainActor final class PollerRig {
    let box: TestSandbox
    let vault: Vault
    let clock = TestClock()
    let stub: TestHTTPStub
    let sleeper = RecordingSleeper()
    let state: AppState
    let tools: [Tool: FakeTool]
    let renewer: Renewer?
    let poller: Poller

    let pacer: ClockSleeper

    init(live: [Tool: [LiveState]] = [:], renewing: Bool = false, persistReadings: Bool = false, spacing: TimeInterval = 0,
         reply: @escaping @Sendable (TestHTTPStub.Request) async -> TestHTTPStub.Reply = okReply) throws {
        box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        vault = try Vault(supportRoot: box.supportRoot)
        stub = TestHTTPStub(reply)
        state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: clock.closure)
        var fakes: [Tool: FakeTool] = [:]
        for tool in Tool.allCases { fakes[tool] = FakeTool(tool, live[tool] ?? [.notSignedIn]) }
        tools = fakes
        let http = HTTPClient(session: stub.session)
        let adapters = Tool.allCases.map { fakes[$0]! as any ToolAdapter }
        renewer = renewing ? Renewer(http: http, tools: adapters, now: clock.closure) : nil
        let fetcher = AllowanceFetcher(http: http, version: "0.1.0", now: clock.closure)
        pacer = ClockSleeper(clock)
        poller = Poller(state: state, tools: adapters, vault: vault, fetcher: fetcher, sleeper: sleeper, now: clock.closure, renewer: renewer,
                        readingsFile: persistReadings ? box.supportRoot.appending(path: "readings.json") : nil, spacing: spacing, pacer: pacer)
    }

    @discardableResult
    func save(_ login: LiveLogin, allowIncomplete: Bool = false, origin: VaultOrigin = .save) async throws -> AccountKey {
        try await vault.save(.signedIn(login), origin: origin, allowIncomplete: allowIncomplete)
        return testKey(login)
    }

    nonisolated var tags: [String] { stub.requests.compactMap(requestTag) }
    nonisolated func count(_ tag: String) -> Int { tags.filter { $0 == tag }.count }
    /// Requests to an OAuth token endpoint.
    nonisolated var tokenRequests: [TestHTTPStub.Request] { stub.requests.filter { isTokenRequest($0) } }
}

func isTokenRequest(_ request: TestHTTPStub.Request) -> Bool {
    ["platform.claude.com", "auth.openai.com", "oauth2.googleapis.com"].contains(request.url.host ?? "")
}

/// Replies in order; the last one repeats.
final class ReplyScript: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [TestHTTPStub.Reply]
    init(_ replies: [TestHTTPStub.Reply]) { self.replies = replies }
    func next() -> TestHTTPStub.Reply { lock.withLock { replies.count > 1 ? replies.removeFirst() : replies[0] } }
}

/// Advances the test clock by each requested sleep and records it; never blocks.
final class ClockSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    let clock: TestClock
    init(_ clock: TestClock) { self.clock = clock }
    var durations: [Duration] { lock.withLock { recorded } }
    func sleep(for duration: Duration) async throws {
        lock.withLock { recorded.append(duration) }
        clock.advance(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}
