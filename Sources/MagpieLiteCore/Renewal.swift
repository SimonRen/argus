import Foundation

public enum RenewalTrigger: Sendable, Equatable {
    /// The stored token expires within 5 minutes.
    case nearExpiry(accessToken: String)
    /// The fetch with this token returned 401.
    case unauthorized(accessToken: String)

    var accessToken: String {
        switch self {
        case .nearExpiry(let t), .unauthorized(let t): t
        }
    }
}

public enum RenewalOutcome: Sendable, Equatable { case renewed, skipped(String), refused, transient(String), appNeedsUpdate }

/// Renews saved, non-live logins with each vendor's refresh-token grant. The live login is never renewed here: its tool
/// owns it. agy's live access token alone may be minted in memory (`liveAgyAccessToken`), never stored.
public actor Renewer {
    let http: HTTPClient
    let tools: [Tool: any ToolAdapter]
    let now: @Sendable () -> Date
    private var blocked: Set<String> = []
    /// Access tokens minted for agy's live login, per account, with the refresh token they came from.
    private var minted: [AccountKey: (refresh: String, token: String, expiry: Date)] = [:]

    static let claudeURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let codexURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let googleURL = URL(string: "https://oauth2.googleapis.com/token")!

    public init(http: HTTPClient, tools: [any ToolAdapter], now: @escaping @Sendable () -> Date) {
        self.http = http
        self.tools = Dictionary(tools.map { ($0.tool, $0) }, uniquingKeysWith: { first, _ in first })
        self.now = now
    }

    /// Drew `invalid_client` since this renewer was made (i.e. since launch).
    public func isBlocked(clientID: String) -> Bool { blocked.contains(clientID) }

    /// An access token for agy's live login when its own has expired. Google refresh tokens don't turn over, so minting
    /// one leaves agy's login untouched; it is kept in memory only, reused until a minute before it expires. Nil when
    /// the client has no embedded secret or the grant fails.
    public func liveAgyAccessToken(_ key: AccountKey, refreshToken: String, clientID: String?) async -> String? {
        if let cached = minted[key], cached.refresh == refreshToken, cached.expiry > now().addingTimeInterval(60) { return cached.token }
        let client = clientID ?? OAuthClients.antigravityClientID
        guard !blocked.contains(client), let secret = OAuthClients.antigravitySecret(forClientID: client),
              case .success(let reply) = await googleGrant(refresh: refreshToken, client: client, secret: secret),
              let access = nonEmpty(reply["access_token"]) else { return nil }
        minted[key] = (refreshToken, access, now().addingTimeInterval(number(reply["expires_in"]) ?? 3600))
        return access
    }

    /// Runs in the tool's exclusive section; once sent, the request completes and its result is persisted even if the
    /// caller goes away.
    public func renew(_ key: AccountKey, trigger: RenewalTrigger, vault: Vault) async -> RenewalOutcome {
        do {
            return try await vault.exclusive(key.tool) { await self.renewInSection(key, trigger, vault) }
        } catch {
            return .transient("interrupted")
        }
    }

    private func renewInSection(_ key: AccountKey, _ trigger: RenewalTrigger, _ vault: Vault) async -> RenewalOutcome {
        guard let adapter = tools[key.tool] else { return .skipped("no live reader") }
        switch await adapter.readLive() {
        case .unknown, .unsupported: return .skipped("live login unreadable")
        case .signedIn(let live) where !live.identity.isComplete: return .skipped("live identity incomplete")
        case .signedIn(let live) where live.identity.fileID == key.id: return .skipped("live account")
        default: break
        }
        guard case .valid(let envelope)? = await vault.entry(key.tool, id: key.id) else { return .skipped("entry gone or unreadable") }
        guard envelope.identity.isComplete, let payload = envelope.payloadBytes else { return .skipped("entry incomplete") }
        let tokens = tokenSet(key.tool, bytes: payload)
        guard (tokens?.accessToken ?? "") == trigger.accessToken else { return .skipped("token already replaced") }
        guard let refresh = tokens?.refreshToken else { return .refused }
        let result: Result<Data, RenewalFailure>
        switch key.tool {
        case .claude: result = await renewClaude(payload, refresh: refresh)
        case .codex: result = await renewCodex(payload, refresh: refresh)
        case .agy:
            guard let client = envelope.clientId, let secret = OAuthClients.antigravitySecret(forClientID: client), !blocked.contains(client) else {
                return .appNeedsUpdate
            }
            result = await renewAgy(payload, refresh: refresh, client: client, secret: secret)
        }
        switch result {
        case .success(let bytes):
            do {
                try await vault.replacePayload(key.tool, id: key.id, bytes: bytes, origin: .renewal)
                return .renewed
            } catch {
                return .transient("couldn't save the renewed login")
            }
        case .failure(.refused): return .refused
        case .failure(.appNeedsUpdate): return .appNeedsUpdate
        case .failure(.transient(let why)): return .transient(why)
        }
    }

    private enum RenewalFailure: Error { case refused, appNeedsUpdate, transient(String) }

    // MARK: - Vendors

    private func renewClaude(_ payload: Data, refresh: String) async -> Result<Data, RenewalFailure> {
        var r = URLRequest(url: Self.claudeURL)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.claudeClientID])
        switch await http.send(r) {
        case .response(200, _, let body):
            guard let reply = jsonObject(body), let access = nonEmpty(reply["access_token"]),
                  var item = jsonObject(payload), var oauth = item["claudeAiOauth"] as? [String: Any] else { return .failure(.transient("unexpected reply")) }
            oauth["accessToken"] = access
            if let rotated = nonEmpty(reply["refresh_token"]) { oauth["refreshToken"] = rotated }
            if let seconds = number(reply["expires_in"]) { oauth["expiresAt"] = Int((now().timeIntervalSince1970 + seconds) * 1000) }
            if let scope = reply["scope"] as? String { oauth["scopes"] = scope.split(whereSeparator: \.isWhitespace).map(String.init) }
            item["claudeAiOauth"] = oauth
            return Self.serialized(item)
        case .response(let status, _, let body) where [400, 401, 403].contains(status) && jsonObject(body)?["error"] as? String == "invalid_grant":
            return .failure(.refused)
        case let other:
            return .failure(.transient(Self.describe(other)))
        }
    }

    private func renewCodex(_ payload: Data, refresh: String) async -> Result<Data, RenewalFailure> {
        var r = URLRequest(url: Self.codexURL)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": Self.codexClientID, "grant_type": "refresh_token", "refresh_token": refresh, "scope": "openid profile email",
        ])
        switch await http.send(r) {
        case .response(200, _, let body):
            guard let reply = jsonObject(body), let access = nonEmpty(reply["access_token"]),
                  var auth = jsonObject(payload) else { return .failure(.transient("unexpected reply")) }
            var tokens = auth["tokens"] as? [String: Any] ?? [:]
            tokens["access_token"] = access
            if let id = nonEmpty(reply["id_token"]) { tokens["id_token"] = id }
            if let rotated = nonEmpty(reply["refresh_token"]) { tokens["refresh_token"] = rotated }
            auth["tokens"] = tokens
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            auth["last_refresh"] = stamp.string(from: now())
            return Self.serialized(auth)
        case .response(400, _, _), .response(401, _, _):
            return .failure(.refused)
        case let other:
            return .failure(.transient(Self.describe(other)))
        }
    }

    private func renewAgy(_ payload: Data, refresh: String, client: String, secret: String) async -> Result<Data, RenewalFailure> {
        switch await googleGrant(refresh: refresh, client: client, secret: secret) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let reply):
            guard let access = nonEmpty(reply["access_token"]),
                  case .object(var json)? = agyPayload(payload) else { return .failure(.transient("unexpected reply")) }
            var token = json["token"] as? [String: Any] ?? [:]
            token["access_token"] = access
            if let seconds = number(reply["expires_in"]) {
                let stamp = ISO8601DateFormatter()
                stamp.formatOptions = [.withInternetDateTime]
                token["expiry"] = stamp.string(from: now().addingTimeInterval(seconds))
            }
            if let rotated = nonEmpty(reply["refresh_token"]) { token["refresh_token"] = rotated }
            json["token"] = token
            if let id = nonEmpty(reply["id_token"]) { json["id_token"] = id }
            return Self.serialized(json).map { Data(("go-keyring-base64:" + $0.base64EncodedString()).utf8) }
        }
    }

    /// Google's refresh-token grant for `client`. -> the reply object; `invalid_client` blocks the client until relaunch.
    private func googleGrant(refresh: String, client: String, secret: String) async -> Result<[String: Any], RenewalFailure> {
        var r = URLRequest(url: Self.googleURL)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let form = [("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", client), ("client_secret", secret)]
        r.httpBody = Data(form.map { "\($0)=\(Self.formEncoded($1))" }.joined(separator: "&").utf8)
        switch await http.send(r) {
        case .response(200, _, let body):
            guard let reply = jsonObject(body) else { return .failure(.transient("unexpected reply")) }
            return .success(reply)
        case .response(let status, _, let body) where status == 400 || status == 401:
            let error = jsonObject(body)?["error"]
            if Self.errorCode(error) == "invalid_client" {
                blocked.insert(client)
                return .failure(.appNeedsUpdate)
            }
            if status == 400, Self.errorCode(error) == "invalid_grant" { return .failure(.refused) }
            return .failure(.transient("HTTP \(status)"))
        case let other:
            return .failure(.transient(Self.describe(other)))
        }
    }

    // MARK: - Helpers

    /// A Google `error`: a string, or an object whose `status` or `code` names it.
    private static func errorCode(_ error: Any?) -> String? {
        if let s = error as? String { return s.lowercased() }
        guard let o = error as? [String: Any] else { return nil }
        return ((o["status"] as? String) ?? (o["code"] as? String))?.lowercased()
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func serialized(_ object: [String: Any]) -> Result<Data, RenewalFailure> {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return .failure(.transient("couldn't encode the renewed login"))
        }
        return .success(data)
    }

    private static func describe(_ outcome: HTTPOutcome) -> String {
        switch outcome {
        case .response(let status, _, _): "HTTP \(status)"
        case .timedOut: "timed out"
        case .failed(let why): why
        }
    }
}
