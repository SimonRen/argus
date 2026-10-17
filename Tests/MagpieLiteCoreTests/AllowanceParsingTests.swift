import Foundation
import Testing
import MagpieLiteCore

fileprivate let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

fileprivate let claudeFixture = #"{"five_hour":{"utilization":7.0,"resets_at":null},"seven_day":{"utilization":72.0,"resets_at":null},"seven_day_opus":null,"limits":[{"kind":"session","group":"session","percent":7,"resets_at":null,"scope":null,"is_active":false},{"kind":"weekly_all","group":"weekly","percent":72,"resets_at":null,"scope":null,"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical","resets_at":"2026-07-08T09:00:00.283070+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}"#

fileprivate let codexFixture = #"{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1767225600},"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_after_seconds":86400,"reset_at":1767312000}},"credits":{"has_credits":false,"unlimited":false,"balance":null}}"#

fileprivate let agyFixture = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.75,"resetTime":"2099-01-07T00:00:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9545545,"resetTime":"2099-01-01T05:00:00Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","resetTime":"2099-01-06T00:00:00Z"},{"bucketId":"3p-5h","window":"5h","remainingFraction":0.7,"resetTime":"2099-01-01T03:00:00Z"},{"bucketId":"3p-x","window":"5h","remainingFraction":1,"disabled":true}]}]}"#

fileprivate func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

fileprivate func fetcher(_ stub: TestHTTPStub, timeout: TimeInterval = HTTPClient.defaultTimeout) -> AllowanceFetcher {
    AllowanceFetcher(http: HTTPClient(session: stub.session, timeout: timeout), version: "0.1.0", now: { fixedNow })
}

@Suite struct AllowanceParsingTests {
    // MARK: F04-AC-4.c1 — Claude windows

    @Test func `REQ/F04-AC-4.c1 Claude All models is 100 minus utilization per window`() throws {
        let groups = try AllowanceParser.claude(Data(claudeFixture.utf8))
        #expect(groups.first == AllowanceGroup(name: "All models", fiveHour: AllowanceWindow(remaining: 93, resetsAt: nil),
                                               sevenDay: AllowanceWindow(remaining: 28, resetsAt: nil)))
    }

    @Test func `REQ/F04-AC-4.c1 Claude resets parse with any fractional digits or none and an absent or null window is missing`() throws {
        let body = #"{"five_hour":{"utilization":40.5,"resets_at":"2026-10-17T05:00:00+02:00"},"seven_day":null}"#
        let groups = try AllowanceParser.claude(Data(body.utf8))
        #expect(groups == [AllowanceGroup(name: "All models", fiveHour: AllowanceWindow(remaining: 59.5, resetsAt: iso("2026-10-17T03:00:00Z")), sevenDay: nil)])
        let other = try AllowanceParser.claude(Data(#"{"seven_day":{"utilization":10,"resets_at":"2026-10-17T03:00:00.1234567Z"}}"#.utf8))
        #expect(other[0].fiveHour == nil)
        #expect(abs(other[0].sevenDay!.resetsAt!.timeIntervalSince(iso("2026-10-17T03:00:00Z")) - 0.1234567) < 0.000_01)
    }

    @Test func `Claude rejects a body that is not a JSON object`() {
        #expect(throws: (any Error).self) { try AllowanceParser.claude(Data("[]".utf8)) }
    }

    // MARK: F04-AC-4.c18 — Claude model-scoped weekly groups

    @Test func `REQ/F04-AC-4.c18 a weekly_scoped limit becomes a weekly-only group named by its model`() throws {
        let groups = try AllowanceParser.claude(Data(claudeFixture.utf8))
        #expect(groups.count == 2)
        #expect(groups[1] == AllowanceGroup(name: "Fable", fiveHour: nil,
                                            sevenDay: AllowanceWindow(remaining: 0, resetsAt: iso("2026-07-08T09:00:00Z").addingTimeInterval(0.28307))))
    }

    @Test func `REQ/F04-AC-4.c18 all-models scopes, unnamed entries and non-numeric percents are skipped and duplicates collapse`() throws {
        func scoped(_ id: String?, _ name: String?, _ percent: String) -> String {
            let idJSON = id.map { "\"\($0)\"" } ?? "null"
            let nameJSON = name.map { "\"\($0)\"" } ?? "null"
            return #"{"kind":"weekly_scoped","group":"weekly","percent":\#(percent),"resets_at":null,"scope":{"model":{"id":\#(idJSON),"display_name":\#(nameJSON)}}}"#
        }
        let limits = [
            scoped(nil, "ALL MODELS", "10"), scoped(nil, nil, "10"), scoped(nil, "", "10"), scoped(nil, "Bad", "\"high\""), scoped(nil, "Flag", "true"),
            scoped("m-1", "Opus", "20"), scoped("m-1", "Opus again", "30"), scoped(nil, "Sonnet", "40"), scoped(nil, "Sonnet", "50"),
            scoped("m-2", "Sonnet", "60"),
            #"{"kind":"weekly_scoped","group":"session","percent":5,"scope":{"model":{"id":null,"display_name":"Session"}}}"#,
        ].joined(separator: ",")
        let groups = try AllowanceParser.claude(Data(#"{"five_hour":null,"seven_day":null,"limits":[\#(limits)]}"#.utf8))
        #expect(groups.map(\.name) == ["All models", "Opus", "Sonnet", "Sonnet"])
        #expect(groups.map { $0.sevenDay?.remaining } == [nil, 80, 60, 40])
    }

    @Test func `REQ/F04-AC-4.c18 no limits gives only All models`() throws {
        let groups = try AllowanceParser.claude(Data(#"{"five_hour":{"utilization":1},"seven_day":{"utilization":2},"seven_day_opus":{"utilization":99}}"#.utf8))
        #expect(groups.map(\.name) == ["All models"])
    }

    // MARK: F04-AC-4.c2 — Codex windows

    @Test func `REQ/F04-AC-4.c2 Codex windows are placed by limit_window_seconds`() throws {
        let groups = try AllowanceParser.codex(Data(codexFixture.utf8))
        #expect(groups == [AllowanceGroup(name: "", fiveHour: AllowanceWindow(remaining: 88, resetsAt: Date(timeIntervalSince1970: 1_767_225_600)),
                                          sevenDay: AllowanceWindow(remaining: 60, resetsAt: Date(timeIntervalSince1970: 1_767_312_000)))])
    }

    @Test func `REQ/F04-AC-4.c2 a weekly-only Codex response has no 5 h window and unknown spans are ignored`() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":604800,"reset_at":1767312000},"secondary_window":{"used_percent":5,"limit_window_seconds":86400,"reset_at":1}}}"#
        let groups = try AllowanceParser.codex(Data(body.utf8))
        #expect(groups == [AllowanceGroup(name: "", fiveHour: nil, sevenDay: AllowanceWindow(remaining: 70, resetsAt: Date(timeIntervalSince1970: 1_767_312_000)))])
        let nullWindows = try AllowanceParser.codex(Data(#"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#.utf8))
        #expect(nullWindows == [AllowanceGroup(name: "", fiveHour: nil, sevenDay: nil)])
    }

    // MARK: F04-AC-4.c3 — agy groups

    @Test func `REQ/F04-AC-4.c3 agy buckets map per group with fractions and disabled buckets skipped`() throws {
        let groups = try AllowanceParser.agy(Data(agyFixture.utf8))
        #expect(groups.map(\.name) == ["Gemini", "Claude and GPT"])
        #expect(abs(groups[0].fiveHour!.remaining - 95.45545) < 0.0001)
        #expect(groups[0].fiveHour!.resetsAt == iso("2099-01-01T05:00:00Z"))
        #expect(groups[0].sevenDay == AllowanceWindow(remaining: 75, resetsAt: iso("2099-01-07T00:00:00Z")))
        #expect(groups[1].fiveHour == AllowanceWindow(remaining: 70, resetsAt: iso("2099-01-01T03:00:00Z")))
        #expect(groups[1].sevenDay == AllowanceWindow(remaining: 0, resetsAt: iso("2099-01-06T00:00:00Z")))
    }

    @Test func `REQ/F04-AC-4.c3 agy infers windows from bucket names and accepts nested fractions and wrapped groups`() throws {
        let body = #"{"response":{"groups":[{"name":"Models","buckets":[{"bucketId":"models_five_hour","remaining":{"remainingFraction":0.5}},{"displayName":"Weekly limit","remaining":{"case":"remainingFraction","value":0.25}},{"bucketId":"daily","remainingFraction":0.1}]},{"displayName":"Other","buckets":[{"bucketId":"x-session","remainingFraction":1.4},{"bucketId":"y-5-hour","remainingFraction":0.3}]}]}}"#
        let groups = try AllowanceParser.agy(Data(body.utf8))
        #expect(groups == [
            AllowanceGroup(name: "Models", fiveHour: AllowanceWindow(remaining: 50, resetsAt: nil), sevenDay: AllowanceWindow(remaining: 25, resetsAt: nil)),
            AllowanceGroup(name: "Other", fiveHour: AllowanceWindow(remaining: 100, resetsAt: nil), sevenDay: nil),
        ])
        let summary = try AllowanceParser.agy(Data(#"{"summary":{"groups":[{"displayName":"G","buckets":[{"bucketId":"g-5h"}]}]}}"#.utf8))
        #expect(summary == [AllowanceGroup(name: "G", fiveHour: AllowanceWindow(remaining: 0, resetsAt: nil), sevenDay: nil)])
        #expect(throws: (any Error).self) { try AllowanceParser.agy(Data("{}".utf8)) }
    }

    // MARK: F04-AC-4.c14 — Claude request and error detail

    @Test func `REQ/F04-AC-4.c14 the Claude usage request carries bearer, beta and the app user agent`() async throws {
        let stub = TestHTTPStub { _ in .json(200, claudeFixture) }
        let result = await fetcher(stub).fetch(.claude, accountKey: "k", accessToken: "test-access-1", accountID: nil)
        guard case .reading(let reading) = result else { Issue.record("got \(result)"); return }
        #expect(reading.fetchedAt == fixedNow)
        #expect(reading.groups.first?.name == "All models")
        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.header("Authorization") == "Bearer test-access-1")
        #expect(request.header("anthropic-beta") == "oauth-2025-04-20")
        #expect(request.header("User-Agent") == "magpie-lite/0.1.0")
    }

    @Test func `REQ/F04-AC-4.c14 a non-200 status keeps the vendor's message as the error detail, never raw body bytes`() async {
        let cases: [(String, String)] = [
            (#"{"error":"overloaded"}"#, "HTTP 500: overloaded"),
            (#"{"error":{"type":"x","message":"Your account is suspended"}}"#, "HTTP 500: Your account is suspended"),
            (#"{"message":"slow down"}"#, "HTTP 500: slow down"),
            ("Authorization: Bearer test-secret", "HTTP 500"),
        ]
        for (body, expected) in cases {
            let stub = TestHTTPStub { _ in .json(500, body) }
            #expect(await fetcher(stub).fetch(.claude, accountKey: "k", accessToken: "test-access-1", accountID: nil) == .failed(expected))
        }
    }

    @Test func `status mapping for 401, 429 and a long error body`() async {
        let long = String(repeating: "e", count: 500)
        let replies: [(TestHTTPStub.Reply, FetchResult)] = [
            (.json(401, "{}"), .unauthorized),
            (.json(429, "{}", headers: ["Retry-After": "120"]), .rateLimited(retryAfter: 120)),
            (.json(429, "{}"), .rateLimited(retryAfter: nil)),
            (.json(403, long), .failed("HTTP 403")),
            (.json(403, #"{"message":"\#(long)"}"#), .failed("HTTP 403: " + String(long.prefix(160)))),
            (.json(200, "not json"), .failed("unexpected response")),
            (.fail(.notConnectedToInternet), .failed("network error")),
        ]
        for (reply, expected) in replies {
            let stub = TestHTTPStub { _ in reply }
            #expect(await fetcher(stub).fetch(.claude, accountKey: "k", accessToken: "test-access-1", accountID: nil) == expected)
        }
    }

    @Test func `the Codex request carries bearer, accept and the account id, and keeps the plan`() async throws {
        let stub = TestHTTPStub { _ in .json(200, codexFixture) }
        let result = await fetcher(stub).fetch(.codex, accountKey: "k", accessToken: "test-access-1", accountID: "acct-1")
        guard case .reading(let reading) = result else { Issue.record("got \(result)"); return }
        #expect(reading.plan == "pro")
        let request = try #require(stub.requests.first)
        #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.header("Authorization") == "Bearer test-access-1")
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("chatgpt-account-id") == "acct-1")
        _ = await fetcher(stub).fetch(.codex, accountKey: "k", accessToken: "test-access-1", accountID: nil)
        #expect(stub.requests.last?.header("chatgpt-account-id") == nil)
    }

    // MARK: F04-AC-4.c15 — agy project then quota

    @Test func `REQ/F04-AC-4.c15 agy loads the project once per account then asks the daily host for the quota summary`() async throws {
        let stub = TestHTTPStub { request in
            request.url.absoluteString.hasSuffix(":loadCodeAssist") ? .json(200, #"{"cloudaicompanionProject":"proj-1"}"#) : .json(200, agyFixture)
        }
        let agy = fetcher(stub)
        guard case .reading(let reading) = await agy.fetch(.agy, accountKey: "acct-a", accessToken: "test-access-1", accountID: nil) else {
            Issue.record("no reading"); return
        }
        #expect(reading.groups.count == 2)
        let requests = stub.requests
        #expect(requests.map(\.url.absoluteString) == ["https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
                                                       "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"])
        #expect(requests.allSatisfy { $0.method == "POST" })
        #expect(try JSONSerialization.jsonObject(with: requests[0].body) as? NSDictionary == ["metadata": ["ideType": "ANTIGRAVITY"]])
        #expect(try JSONSerialization.jsonObject(with: requests[1].body) as? NSDictionary == ["project": "proj-1"])
        for request in requests {
            #expect(request.header("User-Agent") == "antigravity/hub/2.9.1 darwin/arm64")
            #expect(request.header("Authorization") == "Bearer test-access-1")
            #expect(request.header("Content-Type") == "application/json")
        }
        _ = await agy.fetch(.agy, accountKey: "acct-a", accessToken: "test-access-1", accountID: nil)
        #expect(stub.requests.count == 3)
        #expect(stub.requests.last?.url.absoluteString.hasSuffix(":retrieveUserQuotaSummary") == true)
        _ = await agy.fetch(.agy, accountKey: "acct-b", accessToken: "test-access-2", accountID: nil)
        #expect(stub.requests.count == 5)
    }

    @Test func `REQ/F04-AC-4.c15 agy accepts a project object and reports a missing project`() async {
        let objectStub = TestHTTPStub { request in
            request.url.absoluteString.hasSuffix(":loadCodeAssist") ? .json(200, #"{"cloudaicompanionProject":{"projectId":"proj-2"}}"#) : .json(200, agyFixture)
        }
        _ = await fetcher(objectStub).fetch(.agy, accountKey: "k", accessToken: "t", accountID: nil)
        #expect(objectStub.requests.last.map { String(decoding: $0.body, as: UTF8.self) } == #"{"project":"proj-2"}"#)
        let none = TestHTTPStub { _ in .json(200, "{}") }
        #expect(await fetcher(none).fetch(.agy, accountKey: "k", accessToken: "t", accountID: nil) == .failed("open agy once to finish setup"))
        #expect(none.requests.count == 1)
        let unauthorized = TestHTTPStub { _ in .json(401, "{}") }
        #expect(await fetcher(unauthorized).fetch(.agy, accountKey: "k", accessToken: "t", accountID: nil) == .unauthorized)
    }

    // MARK: F04-AC-4.c17 — 15 s timeout

    @Test func `REQ/F04-AC-4.c17 a request past the timeout is cancelled and treated as transient`() async {
        #expect(HTTPClient.defaultTimeout == 15)
        let stub = TestHTTPStub { _ in .never }
        let start = Date()
        let outcome = await HTTPClient(session: stub.session, timeout: 0.2).send(URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!))
        #expect(outcome == .timedOut)
        #expect(Date().timeIntervalSince(start) < 1)
        let result = await fetcher(stub, timeout: 0.2).fetch(.claude, accountKey: "k", accessToken: "t", accountID: nil)
        guard case .failed = result else { Issue.record("got \(result)"); return }
    }

    // MARK: rate-limit backoff

    @Test func `rate-limit delay: a long Retry-After gets a 900 s margin capped at 4500 s, a short one is honoured or the curve, none waits 300 to 600 s`() {
        #expect(RateLimitPolicy.nextDelay(strike: 1, retryAfter: 42) == 42)
        #expect(RateLimitPolicy.nextDelay(strike: 4, retryAfter: 42) == 240)
        #expect(RateLimitPolicy.nextDelay(strike: 1, retryAfter: 600) == 600)
        #expect(RateLimitPolicy.nextDelay(strike: 1, retryAfter: 2426) == 3326)
        #expect(RateLimitPolicy.nextDelay(strike: 1, retryAfter: 4000) == 4500)
        #expect((1...7).map { RateLimitPolicy.nextDelay(strike: $0, retryAfter: nil) } == [300, 300, 300, 300, 480, 600, 600])
        #expect(RateLimitPolicy.nextDelay(strike: 1, retryAfter: 0) == 300)
    }
}
