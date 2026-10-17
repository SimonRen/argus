import Foundation
import Testing
import MagpieLiteCore

/// Counts requests running at once.
fileprivate final class Concurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0, peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
    var highest: Int { lock.withLock { peak } }
}

@MainActor @Suite struct PollerTests {
    // MARK: F04-AC-4.c4

    @Test func `REQ/F04-AC-4.c4 a batch fetches each live login and every pollable saved account one at a time`() async throws {
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b"), c = testLogin(.claude, "c", complete: false)
        let e = testLogin(.codex, "e"), f = testLogin(.agy, "f")
        let concurrency = Concurrency()
        let rig = try PollerRig(live: [.claude: [.signedIn(a)], .agy: [.signedIn(f)]]) { request in
            concurrency.enter()
            try? await Task.sleep(for: .milliseconds(5))
            concurrency.leave()
            return okReply(request)
        }
        try await rig.save(a)
        try await rig.save(b)
        try await rig.save(c, allowIncomplete: true)
        try await rig.save(e)
        try rig.box.write("support/vault/claude/\(String(repeating: "d", count: 64)).json", "{}")
        await rig.poller.runBatch()
        #expect(rig.tags == ["a", "b", "e", "f", "f"])
        #expect(concurrency.highest == 1)
        #expect(rig.state.status[testKey(a)]?.reading?.groups.first?.name == "All models")
        #expect(rig.state.status[testKey(b)]?.reading != nil)
        #expect(rig.state.status[testKey(c)] == nil)
        #expect(rig.state.status[testKey(f)]?.reading?.groups.first?.name == "Gemini")
        #expect(rig.state.lastLiveFetch == rig.clock.now)
        #expect(rig.tools[.claude]!.reads == 1)
    }

    @Test func `REQ/F04-AC-4.c4 start runs a batch at launch, then sleeps the chosen interval`() async throws {
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))]])
        rig.poller.start()
        #expect(await eventually { rig.sleeper.durations.count == 1 })
        #expect(rig.sleeper.durations == [.seconds(300)])
        #expect(rig.tags == ["a"])
        rig.poller.stop()
    }

    @Test func `REQ/F04-AC-4.c4 saved accounts are fetched in id order after the live login`() async throws {
        let logins = ["p", "q", "r", "s"].map { testLogin(.codex, $0) }
        let rig = try PollerRig(live: [.codex: [.signedIn(logins[2])]])
        for l in logins { try await rig.save(l) }
        await rig.poller.runBatch()
        let savedOrder = logins.filter { $0.label != "r@example.com" }.sorted { $0.identity.fileID < $1.identity.fileID }.map { String($0.label.prefix(1)) }
        #expect(rig.tags == ["r"] + savedOrder)
    }

    // MARK: F04-AC-4.c5

    @Test func `REQ/F04-AC-4.c5 a 429 backs off only that account, again after a repeat, and a 200 clears it`() async throws {
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b")
        let bReplies = ReplyScript([.json(429, "{}"), .json(429, "{}"), .json(200, claudeUsageOK)])
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { request in requestTag(request) == "b" ? bReplies.next() : okReply(request) }
        try await rig.save(a)
        try await rig.save(b)
        let start = rig.clock.now
        await rig.poller.runBatch()
        #expect(rig.count("a") == 1 && rig.count("b") == 1)
        #expect(rig.state.rateLimitedUntil[testKey(b)] == start + 300 && rig.state.rateLimitedUntil[testKey(a)] == nil)
        #expect(rig.state.status[testKey(b)]?.stale == true && rig.state.status[testKey(b)]?.error == "rate limited")
        #expect(rig.state.snapshot(.claude).rateLimitedUntil == start + 300)
        rig.clock.advance(200)
        await rig.poller.runBatch()
        #expect(rig.count("b") == 1 && rig.count("a") == 2 && rig.state.status[testKey(a)]?.stale == false)
        rig.clock.advance(101)
        await rig.poller.runBatch()
        #expect(rig.count("b") == 1)
        rig.clock.advance(100)
        await rig.poller.runBatch()
        #expect(rig.count("b") == 2 && rig.state.rateLimitedUntil[testKey(b)] == rig.clock.now + 300)
        rig.clock.advance(400)
        await rig.poller.runBatch()
        #expect(rig.count("b") == 3 && rig.state.rateLimitedUntil[testKey(b)] == nil && rig.state.status[testKey(b)]?.stale == false)
    }

    @Test func `REQ/F04-AC-4.c5 Retry-After sets the skip, then the curve takes over up to 600 s`() async throws {
        let replies = ReplyScript([.json(429, "{}", headers: ["Retry-After": "120"])] + Array(repeating: .json(429, "{}"), count: 8))
        let rig = try PollerRig(live: [.codex: [.signedIn(testLogin(.codex, "a"))]]) { _ in replies.next() }
        await rig.poller.runBatch()
        let key = testKey(testLogin(.codex, "a"))
        #expect(rig.state.rateLimitedUntil[key] == rig.clock.now + 120)
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            rig.clock.advance(2000)
            await rig.poller.runBatch()
            delays.append(rig.state.rateLimitedUntil[key]!.timeIntervalSince(rig.clock.now))
        }
        #expect(delays == [300, 300, 300, 480, 600, 600, 600])
    }

    @Test func `a backoff survives a restart and still holds the account`() async throws {
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]], persistReadings: true) { _ in .json(429, "{}", headers: ["Retry-After": "2426"]) }
        try await rig.save(a)
        let start = rig.clock.now
        await rig.poller.runBatch()
        #expect(rig.state.rateLimitedUntil[testKey(a)] == start + 3326)
        let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: rig.clock.closure)
        let restarted = Poller(state: state, tools: [], vault: rig.vault, fetcher: AllowanceFetcher(http: HTTPClient(session: rig.stub.session), version: "0", now: rig.clock.closure),
                               sleeper: RecordingSleeper(), now: rig.clock.closure, readingsFile: rig.box.supportRoot.appending(path: "readings.json"))
        #expect(state.rateLimitedUntil[testKey(a)] == start + 3326)
        rig.clock.advance(600)
        #expect(await restarted.refresh(testKey(a)) == RefreshDeferral(until: start + 3326, rateLimitedBy: .claude))
        #expect(rig.stub.requests.count == 1)
    }

    // MARK: F04-AC-4.c6

    @Test func `REQ/F04-AC-4.c6 a failed fetch keeps the last good reading, marked stale with its age`() async throws {
        let replies = ReplyScript([.json(200, claudeUsageOK), .json(503, "busy"), .fail(.networkConnectionLost), .json(200, "garbage")])
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { _ in replies.next() }
        await rig.poller.runBatch()
        let good = try #require(rig.state.status[testKey(a)]?.reading)
        #expect(good.fetchedAt == rig.clock.now)
        for expected in ["HTTP 503: busy", "network error", "unexpected response"] {
            rig.clock.advance(300)
            await rig.poller.runBatch()
            let status = try #require(rig.state.status[testKey(a)])
            #expect(status.reading == good)
            #expect(status.stale)
            #expect(status.error == expected)
            #expect(rig.state.snapshot(.claude).accounts.first?.stale == true)
        }
    }

    // MARK: F04-AC-4.c13

    @Test func `REQ/F04-AC-4.c13 a live fetch uses the live token and an expired one sends nothing and marks stale`() async throws {
        let fresh = testLogin(.claude, "a")
        let expired = testLogin(.claude, "a", expiry: Date(timeIntervalSince1970: 1_000))
        let rig = try PollerRig(live: [.claude: [.signedIn(fresh), .signedIn(expired)]])
        try await rig.save(testLogin(.claude, "a"))
        await rig.poller.runBatch()
        #expect(rig.tags == ["a"])
        #expect(rig.stub.requests.allSatisfy { $0.url.host == "api.anthropic.com" && $0.url.path == "/api/oauth/usage" })
        rig.clock.advance(300)
        await rig.poller.runBatch()
        #expect(rig.tags == ["a"])
        #expect(rig.state.status[testKey(fresh)]?.stale == true)
        #expect(rig.state.status[testKey(fresh)]?.reading != nil)
    }

    // MARK: F04-AC-4.c16

    @Test func `REQ/F04-AC-4.c16 a Codex reading under 60 s old is reused instead of fetched`() async throws {
        let e = testLogin(.codex, "e"), g = testLogin(.codex, "g")
        let rig = try PollerRig(live: [.codex: [.signedIn(e)]])
        try await rig.save(g)
        await rig.poller.runBatch()
        #expect(rig.tags == ["e", "g"])
        rig.clock.advance(30)
        await rig.poller.refreshLive()
        await rig.poller.refresh(testKey(g))
        rig.clock.advance(20)
        await rig.poller.runBatch()
        #expect(rig.tags == ["e", "g"])
        rig.clock.advance(11)
        await rig.poller.refreshLive()
        #expect(rig.tags == ["e", "g", "e"])
    }

    @Test func `REQ/F04-AC-4.c16 a Claude account asked for under 180 s ago, even unsuccessfully, is not sent again and the refresh says until when`() async throws {
        let replies = ReplyScript([.json(503, "busy"), .json(200, claudeUsageOK)])
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { _ in replies.next() }
        let start = rig.clock.now
        await rig.poller.runBatch()
        rig.clock.advance(10)
        #expect(await rig.poller.refreshLive() == RefreshDeferral(until: start + 180, rateLimitedBy: nil))
        #expect(await rig.poller.refresh(testKey(a)) == RefreshDeferral(until: start + 180, rateLimitedBy: nil))
        #expect(rig.tags == ["a"])
        #expect(rig.state.lastLiveFetch == start)
        rig.clock.advance(150)
        #expect(await rig.poller.refreshLive() != nil)
        await rig.poller.runBatch()
        #expect(rig.tags == ["a"])
        rig.clock.advance(20)
        #expect(await rig.poller.refreshLive() == nil)
        #expect(rig.tags == ["a", "a"])
        #expect(rig.state.lastLiveFetch == rig.clock.now)
    }

    @Test func `REQ/F04-AC-4.c16 a refresh held by a 429 backoff names the vendor and sends nothing`() async throws {
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { _ in .json(429, "{}", headers: ["Retry-After": "120"]) }
        await rig.poller.runBatch()
        rig.clock.advance(90)
        #expect(await rig.poller.refresh(testKey(a)) == RefreshDeferral(until: rig.clock.now + 30, rateLimitedBy: .claude))
        #expect(rig.tags == ["a"])
    }

    @Test func `the last readings survive a restart, shown stale until fetched again; an unreadable file is ignored`() async throws {
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]], persistReadings: true)
        await rig.poller.runBatch()
        let reading = try #require(rig.state.status[testKey(a)]?.reading)
        let file = rig.box.supportRoot.appending(path: "readings.json")
        func restart() -> AppState {
            let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: rig.clock.closure)
            _ = Poller(state: state, tools: [], vault: rig.vault, fetcher: AllowanceFetcher(http: HTTPClient(session: rig.stub.session), version: "0", now: rig.clock.closure),
                       sleeper: RecordingSleeper(), now: rig.clock.closure, readingsFile: file)
            return state
        }
        let restored = restart()
        #expect(restored.status[testKey(a)]?.reading == reading && restored.status[testKey(a)]?.stale == true)
        try Data("garbage".utf8).write(to: file)
        #expect(restart().status.isEmpty)
    }

    @Test func `an account shows as fetching only while its request is in flight`() async throws {
        let gate = TestGate()
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { request in await gate.wait(); return okReply(request) }
        try await rig.save(b)
        await rig.poller.reloadVault()
        let refresh = Task { await rig.poller.refreshLive() }
        #expect(await eventually { rig.stub.requests.count == 1 })
        #expect(rig.state.snapshot(.claude).accounts.first { $0.key == testKey(a) }?.fetching == true)
        #expect(rig.state.snapshot(.claude).accounts.first { $0.key == testKey(b) }?.fetching == false)
        #expect(rig.state.snapshot(.claude).hidingMinorGroups.accounts.first { $0.key == testKey(a) }?.fetching == true)
        await gate.release()
        await refresh.value
        #expect(rig.state.fetching.isEmpty)
    }

    @Test func `for an hour after a backoff ends an account is asked at most every 360 s, then every 180 s again`() async throws {
        let replies = ReplyScript([.json(429, "{}"), .json(200, claudeUsageOK)])
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { _ in replies.next() }
        let start = rig.clock.now
        await rig.poller.runBatch()
        #expect(rig.state.rateLimitedUntil[testKey(a)] == start + 300)
        rig.clock.advance(360)
        #expect(await rig.poller.refresh(testKey(a)) == nil)
        rig.clock.advance(200)
        #expect(await rig.poller.refresh(testKey(a)) == RefreshDeferral(until: start + 720, rateLimitedBy: nil))
        rig.clock.advance(3600)
        #expect(await rig.poller.refresh(testKey(a)) == nil)
        rig.clock.advance(170)
        #expect(await rig.poller.refresh(testKey(a)) == RefreshDeferral(until: rig.clock.now + 10, rateLimitedBy: nil))
        #expect(rig.count("a") == 3)
    }

    @Test func `usage requests to one vendor go one at a time, spaced apart; other vendors are not held`() async throws {
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b"), c = testLogin(.claude, "c"), x = testLogin(.codex, "x")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)], .codex: [.signedIn(x)]], spacing: 2)
        try await rig.save(b)
        try await rig.save(c)
        await rig.poller.runBatch()
        #expect(rig.tags.filter { ["a", "b", "c"].contains($0) } == ["a", "b", "c"] || rig.tags.filter { ["a", "b", "c"].contains($0) } == ["a", "c", "b"])
        #expect(rig.pacer.durations == [.seconds(2), .seconds(2)])
        #expect(rig.count("x") == 1)
    }

    @Test func `two refreshes of one vendor's accounts never overlap`() async throws {
        let gate = TestGate()
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]], spacing: 2) { request in
            if requestTag(request) == "a" { await gate.wait() }
            return okReply(request)
        }
        try await rig.save(a)
        try await rig.save(b)
        await rig.poller.reloadVault()
        let first = Task { await rig.poller.refresh(testKey(a)) }
        #expect(await eventually { rig.stub.requests.count == 1 })
        let second = Task { await rig.poller.refresh(testKey(b)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.stub.requests.count == 1)
        await gate.release()
        _ = await first.value
        _ = await second.value
        #expect(rig.tags == ["a", "b"])
        #expect(rig.pacer.durations == [.seconds(2)])
    }

    // MARK: F04-AC-4.c19

    @Test func `REQ/F04-AC-4.c19 Refresh live accounts fetches only live logins and leaves the interval timer alone`() async throws {
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b"), f = testLogin(.agy, "f")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)], .agy: [.signedIn(f)]])
        try await rig.save(b)
        rig.poller.start()
        #expect(await eventually { rig.sleeper.durations.count == 1 })
        let before = rig.tags
        rig.clock.advance(180)
        await rig.poller.refreshLive()
        #expect(Array(rig.tags.dropFirst(before.count)) == ["a", "f"])
        #expect(rig.sleeper.durations.count == 1)
        #expect(rig.state.lastLiveFetch == rig.clock.now)
        rig.poller.stop()
    }

    @Test func `REQ/F04-AC-4.c19 Refresh live accounts obeys a rate limit`() async throws {
        let replies = ReplyScript([.json(429, "{}")])
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))]]) { _ in replies.next() }
        await rig.poller.runBatch()
        rig.clock.advance(10)
        await rig.poller.refreshLive()
        #expect(rig.tags == ["a"])
    }

    // MARK: F04-AC-4.c21

    @Test func `REQ/F04-AC-4.c21 a refresh of an account in flight in a batch joins it`() async throws {
        let gate = TestGate()
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { request in
            if requestTag(request) == "a" { await gate.wait() }
            return okReply(request)
        }
        let poller = rig.poller
        let batch = Task { await poller.runBatch() }
        #expect(await eventually { rig.count("a") == 1 })
        let refresh = Task { await poller.refresh(testKey(a)) }
        let live = Task { await poller.refreshLive() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        await batch.value
        await refresh.value
        await live.value
        #expect(rig.count("a") == 1)
    }

    @Test func `REQ/F04-AC-4.c21 a refresh of an account queued in a batch waits for the batch's fetch`() async throws {
        let gate = TestGate()
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { request in
            if requestTag(request) == "a" { await gate.wait() }
            return okReply(request)
        }
        try await rig.save(b)
        let poller = rig.poller
        let batch = Task { await poller.runBatch() }
        #expect(await eventually { rig.count("a") == 1 })
        let refreshed = DoneFlag()
        let refresh = Task { await poller.refresh(testKey(b)); refreshed.set() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.count("b") == 0 && !refreshed.done)
        await gate.release()
        await batch.value
        await refresh.value
        #expect(rig.count("b") == 1)
        #expect(rig.state.status[testKey(b)]?.reading != nil)
    }

    @Test func `REQ/F04-AC-4.c21 a batch reaching an account whose refresh is in flight joins it`() async throws {
        let gate = TestGate()
        let b = testLogin(.codex, "b")
        let rig = try PollerRig() { request in
            if requestTag(request) == "b" { await gate.wait() }
            return okReply(request)
        }
        try await rig.save(b)
        let poller = rig.poller
        let refresh = Task { await poller.refresh(testKey(b)) }
        #expect(await eventually { rig.count("b") == 1 })
        let batch = Task { await poller.runBatch() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        await refresh.value
        await batch.value
        #expect(rig.count("b") == 1)
    }

    @Test func `REQ/F04-AC-4.c21 a second batch request joins the running batch`() async throws {
        let gate = TestGate()
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]]) { request in
            await gate.wait()
            return okReply(request)
        }
        let poller = rig.poller
        let first = Task { await poller.runBatch() }
        #expect(await eventually { rig.count("a") == 1 })
        let second = Task { await poller.runBatch() }
        try await Task.sleep(for: .milliseconds(30))
        await gate.release()
        await first.value
        await second.value
        #expect(rig.count("a") == 1)
        #expect(rig.tools[.claude]!.reads == 1)
    }

    // MARK: F04-AC-4.c23

    @Test func `REQ/F04-AC-4.c23 a live reading stays on the identity read with its token even if the login changes mid-request`() async throws {
        let gate = TestGate()
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b")
        let rig = try PollerRig(live: [.claude: [.signedIn(a), .signedIn(b)]]) { request in
            await gate.wait()
            return okReply(request)
        }
        let poller = rig.poller
        let refresh = Task { await poller.refreshLive() }
        #expect(await eventually { rig.count("a") == 1 })
        rig.tools[.claude]!.script([.signedIn(b)])
        await gate.release()
        await refresh.value
        #expect(rig.state.status[testKey(a)]?.reading != nil)
        #expect(rig.state.status[testKey(b)] == nil)
        #expect(rig.tags == ["a"])
    }

    // MARK: snapshot and interval

    @Test func `snapshot lists every vault entry plus an unsaved live login`() async throws {
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b"), c = testLogin(.claude, "c", complete: false)
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]])
        try await rig.vault.save(.signedIn(b), origin: .kept)
        try await rig.save(c, allowIncomplete: true)
        let bad = String(repeating: "e", count: 64)
        try rig.box.write("support/vault/claude/\(bad).json", "{}")
        await rig.poller.runBatch()
        let accounts = rig.state.snapshot(.claude).accounts
        #expect(accounts.count == 4)
        let live = try #require(accounts.first { $0.key == testKey(a) })
        #expect(live.isLive && !live.isSaved && live.flag == .ok && live.reading != nil && live.label == "a@example.com")
        let saved = try #require(accounts.first { $0.key == testKey(b) })
        #expect(!saved.isLive && saved.isSaved && saved.kept && saved.plan == "pro")
        #expect(accounts.first { $0.key == testKey(c) }?.flag == .incomplete)
        #expect(accounts.first { $0.key.id == bad }?.flag == .unreadable)
        #expect(rig.state.snapshot(.claude).live == .signedIn(a))
        #expect(rig.state.snapshot(.agy).live == .notSignedIn)
    }

    @Test func `the interval reads 3, 5 or 10 minutes from defaults and anything else as 5`() {
        for (stored, expected) in [(3, 3), (5, 5), (10, 10), (7, 5), (0, 5)] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            if stored != 0 { defaults.set(stored, forKey: "intervalMinutes") }
            #expect(AppState(defaults: defaults).intervalMinutes == expected)
        }
    }
}

fileprivate final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var done: Bool { lock.withLock { value } }
}
