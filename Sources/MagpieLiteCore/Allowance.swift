import Foundation

public struct AllowanceWindow: Sendable, Equatable, Codable {
    /// 0…100, clamped.
    public let remaining: Double
    public let resetsAt: Date?

    /// What every percentage on screen shows.
    public var used: Double { 100 - remaining }

    public init(remaining: Double, resetsAt: Date?) {
        self.remaining = min(100, max(0, remaining))
        self.resetsAt = resetsAt
    }
}

public struct AllowanceGroup: Sendable, Equatable, Codable {
    /// "" for an unnamed group.
    public let name: String
    public let fiveHour: AllowanceWindow?
    public let sevenDay: AllowanceWindow?

    public init(name: String, fiveHour: AllowanceWindow?, sevenDay: AllowanceWindow?) {
        self.name = name
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct AllowanceReading: Sendable, Equatable, Codable {
    public let groups: [AllowanceGroup]
    /// Codex `plan_type` · otherwise nil.
    public let plan: String?
    public let fetchedAt: Date

    public init(groups: [AllowanceGroup], plan: String?, fetchedAt: Date) {
        self.groups = groups
        self.plan = plan
        self.fetchedAt = fetchedAt
    }
}

struct ParseError: Error {}

public enum AllowanceParser {
    public static func claude(_ body: Data) throws -> [AllowanceGroup] {
        guard let json = jsonObject(body) else { throw ParseError() }
        func window(_ key: String) -> AllowanceWindow? {
            guard let w = json[key] as? [String: Any], let used = number(w["utilization"]) else { return nil }
            return AllowanceWindow(remaining: 100 - used, resetsAt: (w["resets_at"] as? String).flatMap(parseRFC3339))
        }
        var groups = [AllowanceGroup(name: "All models", fiveHour: window("five_hour"), sevenDay: window("seven_day"))]
        var seen = Set<String>()
        for limit in json["limits"] as? [[String: Any]] ?? [] {
            guard limit["kind"] as? String == "weekly_scoped", limit["group"] as? String == "weekly",
                  let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = nonEmpty(model["display_name"]), name.lowercased() != "all models",
                  let percent = number(limit["percent"]) else { continue }
            let key = model["id"].flatMap { $0 is NSNull ? nil : "id:\($0)" } ?? "name:\(name)"
            guard seen.insert(key).inserted else { continue }
            groups.append(AllowanceGroup(name: name, fiveHour: nil, sevenDay: AllowanceWindow(
                remaining: 100 - percent, resetsAt: (limit["resets_at"] as? String).flatMap(parseRFC3339))))
        }
        return groups
    }

    public static func codex(_ body: Data) throws -> [AllowanceGroup] {
        guard let json = jsonObject(body) else { throw ParseError() }
        let limits = json["rate_limit"] as? [String: Any] ?? [:]
        var five: AllowanceWindow?, seven: AllowanceWindow?
        for key in ["primary_window", "secondary_window"] {
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percent"]) else { continue }
            let window = AllowanceWindow(remaining: 100 - used,
                                         resetsAt: number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) })
            switch number(w["limit_window_seconds"]) {
            case 18000: five = window
            case 604_800: seven = window
            default: break
            }
        }
        return [AllowanceGroup(name: "", fiveHour: five, sevenDay: seven)]
    }

    public static func agy(_ body: Data) throws -> [AllowanceGroup] {
        guard let json = jsonObject(body) else { throw ParseError() }
        let raw = json["groups"] ?? (json["response"] as? [String: Any])?["groups"] ?? (json["summary"] as? [String: Any])?["groups"]
        guard let groups = raw as? [[String: Any]] else { throw ParseError() }
        return groups.map { group in
            var five: AllowanceWindow?, seven: AllowanceWindow?
            for bucket in group["buckets"] as? [[String: Any]] ?? [] where bucket["disabled"] as? Bool != true {
                let window = AllowanceWindow(remaining: fraction(bucket) * 100,
                                             resetsAt: (bucket["resetTime"] as? String).flatMap(parseRFC3339))
                switch agyWindow(bucket) {
                case .fiveHour?: if five == nil { five = window }
                case .sevenDay?: if seven == nil { seven = window }
                case nil: break
                }
            }
            var name = nonEmpty(group["displayName"]) ?? nonEmpty(group["name"]) ?? ""
            if name.lowercased().hasSuffix(" models") { name.removeLast(" models".count) }   // "Gemini Models" → "Gemini"
            return AllowanceGroup(name: name, fiveHour: five, sevenDay: seven)
        }
    }

    private enum Span { case fiveHour, sevenDay }

    private static func agyWindow(_ bucket: [String: Any]) -> Span? {
        switch (bucket["window"] as? String)?.lowercased() {
        case "5h": return .fiveHour
        case "weekly": return .sevenDay
        default: break
        }
        for key in ["bucketId", "displayName"] {
            guard var name = (bucket[key] as? String)?.lowercased().replacingOccurrences(of: "_", with: "-") else { continue }
            if name.hasSuffix(" limit") { name.removeLast(" limit".count) }
            func matches(_ alias: String) -> Bool { name == alias || name.hasSuffix("-" + alias) }
            if ["session", "5h", "5-hour", "five hour", "five-hour"].contains(where: matches) { return .fiveHour }
            if matches("weekly") { return .sevenDay }
        }
        return nil
    }

    private static func fraction(_ bucket: [String: Any]) -> Double {
        if let f = number(bucket["remainingFraction"]) { return f }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return 0 }
        if let f = number(remaining["remainingFraction"]) { return f }
        if remaining["case"] as? String == "remainingFraction", let f = number(remaining["value"]) { return f }
        return 0
    }
}

/// A JSON number that is not a boolean.
func number(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.doubleValue
}

public enum HTTPOutcome: Sendable, Equatable {
    case response(status: Int, headers: [String: String], body: Data)
    case timedOut
    case failed(String)
}

public struct HTTPClient: Sendable {
    public static let defaultTimeout: TimeInterval = 15
    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession, timeout: TimeInterval = HTTPClient.defaultTimeout) {
        self.session = session
        self.timeout = timeout
    }

    /// The request is cancelled after `timeout` → `.timedOut`.
    public func send(_ request: URLRequest) async -> HTTPOutcome {
        let session = session, timeout = timeout
        return await withTaskGroup(of: HTTPOutcome.self) { group in
            group.addTask {
                do {
                    let (body, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { return .failed("not an HTTP response") }
                    var headers: [String: String] = [:]
                    for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
                    return .response(status: http.statusCode, headers: headers, body: body)
                } catch let error as URLError where error.code == .timedOut {
                    return .timedOut
                } catch {
                    return Task.isCancelled ? .timedOut : .failed("network error")
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}

public enum FetchResult: Sendable, Equatable {
    case reading(AllowanceReading)
    /// HTTP 401.
    case unauthorized
    /// HTTP 429, integer Retry-After seconds when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// Timeout, network, 5xx, other non-200, parse error.
    case failed(String)
}

/// Asks each vendor for an account's remaining allowance.
public actor AllowanceFetcher {
    let http: HTTPClient
    let version: String
    let now: @Sendable () -> Date
    private var agyProjects: [String: String] = [:]

    static let claudeURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let codexURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let agyLoadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let agyQuotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    static let agyUserAgent = "antigravity/hub/2.9.1 darwin/arm64"

    public init(http: HTTPClient, version: String, now: @escaping @Sendable () -> Date) {
        self.http = http
        self.version = version
        self.now = now
    }

    public func fetch(_ tool: Tool, accountKey: String, accessToken: String, accountID: String?) async -> FetchResult {
        switch tool {
        case .claude:
            var r = URLRequest(url: Self.claudeURL)
            r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            r.setValue("magpie-lite/\(version)", forHTTPHeaderField: "User-Agent")
            return result(await http.send(r)) { AllowanceReading(groups: try AllowanceParser.claude($0), plan: nil, fetchedAt: self.now()) }
        case .codex:
            var r = URLRequest(url: Self.codexURL)
            r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            if let accountID { r.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id") }
            return result(await http.send(r)) { body in
                AllowanceReading(groups: try AllowanceParser.codex(body), plan: jsonObject(body).flatMap { nonEmpty($0["plan_type"]) },
                                 fetchedAt: self.now())
            }
        case .agy:
            let project: String
            if let cached = agyProjects[accountKey] {
                project = cached
            } else {
                let load = await http.send(agyRequest(Self.agyLoadURL, token: accessToken, body: #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#))
                guard case .response(200, _, let loaded) = load else { return result(load) { _ in throw ParseError() } }
                guard let found = Self.project(loaded) else { return .failed("open agy once to finish setup") }
                agyProjects[accountKey] = found
                project = found
            }
            let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["project": project]), as: UTF8.self)
            return result(await http.send(agyRequest(Self.agyQuotaURL, token: accessToken, body: body))) {
                AllowanceReading(groups: try AllowanceParser.agy($0), plan: nil, fetchedAt: self.now())
            }
        }
    }

    private func agyRequest(_ url: URL, token: String, body: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.agyUserAgent, forHTTPHeaderField: "User-Agent")
        r.httpBody = Data(body.utf8)
        return r
    }

    private static func project(_ body: Data) -> String? {
        switch jsonObject(body)?["cloudaicompanionProject"] {
        case let s as String: return s.isEmpty ? nil : s
        case let o as [String: Any]: return nonEmpty(o["id"]) ?? nonEmpty(o["projectId"])
        default: return nil
        }
    }

    private func result(_ outcome: HTTPOutcome, parse: (Data) throws -> AllowanceReading) -> FetchResult {
        switch outcome {
        case .timedOut: return .failed("timed out")
        case .failed(let why): return .failed(why)
        case .response(200, _, let body):
            guard let reading = try? parse(body) else { return .failed("unexpected response") }
            return .reading(reading)
        case .response(401, _, _): return .unauthorized
        case .response(429, let headers, _):
            let value = headers.first { $0.key.lowercased() == "retry-after" }?.value
            return .rateLimited(retryAfter: value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map(TimeInterval.init))
        case .response(let status, _, let body):
            return .failed("HTTP \(status): \(String(decoding: body.prefix(200), as: UTF8.self))")
        }
    }
}

public enum RateLimitPolicy {
    /// `retryAfter` when given; else 300 s for a first 429, the previous delay × 1.5 for a repeat, capped at 1800 s.
    /// The wait after an account's `strike`-th consecutive 429, as measured on Claude's usage endpoint
    /// (refs/claude-swap usage_store.py): a Retry-After over 600 s gets a 900 s margin, since blocks often re-arm just
    /// after their deadline, capped at 4500 s; a shorter one is honoured, or the growth curve if longer; none (or 0)
    /// waits 300–600 s.
    public static func nextDelay(strike: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let curve = min(30 * pow(2, Double(max(1, strike) - 1)), 600)
        guard let retryAfter, retryAfter > 0 else { return min(max(curve, 300), 600) }
        if retryAfter > 600 { return min(retryAfter + 900, 4500) }
        return max(retryAfter, curve)
    }
}
