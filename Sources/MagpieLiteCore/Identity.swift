import CryptoKit
import Foundation

/// Lowercase hex SHA-256.
public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Who a login belongs to. Complete identities are keyed by account; incomplete ones by their refresh token's
/// fingerprint, so they never match a saved account.
public struct Identity: Codable, Sendable, Hashable {
    public let tool: Tool
    /// Lowercased.
    public let email: String?
    /// Claude `organizationUuid` · Codex `chatgpt_account_id` · agy nil.
    public let scope: String?
    /// agy id_token `sub` · otherwise nil.
    public let subject: String?
    /// `sha256Hex` of the refresh token's UTF-8, set only when incomplete.
    public let incompleteFingerprint: String?

    init(tool: Tool, email: String?, scope: String?, subject: String?, refreshToken: String?) {
        self.tool = tool
        self.email = email.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.scope = scope.flatMap { $0.isEmpty ? nil : $0 }
        self.subject = subject.flatMap { $0.isEmpty ? nil : $0 }
        let complete = switch tool {
        case .claude, .codex: self.email != nil && self.scope != nil
        case .agy: self.subject != nil
        }
        self.incompleteFingerprint = complete ? nil : sha256Hex(Data((refreshToken ?? "").utf8))
    }

    public var isComplete: Bool { incompleteFingerprint == nil }

    public var key: String {
        if let incompleteFingerprint { return "\(tool.rawValue):incomplete:\(incompleteFingerprint)" }
        return switch tool {
        case .claude, .codex: "\(tool.rawValue):\(email ?? ""):\(scope ?? "")"
        case .agy: "agy:\(subject ?? "")"
        }
    }

    public var fileID: String { sha256Hex(Data(key.utf8)) }

    public static func claude(email: String?, organizationUuid: String?, refreshToken: String?) -> Identity {
        Identity(tool: .claude, email: email, scope: organizationUuid, subject: nil, refreshToken: refreshToken)
    }

    public static func codex(email: String?, accountID: String?, refreshToken: String?) -> Identity {
        Identity(tool: .codex, email: email, scope: accountID, subject: nil, refreshToken: refreshToken)
    }

    public static func agy(subject: String?, email: String?, refreshToken: String?) -> Identity {
        Identity(tool: .agy, email: email, scope: nil, subject: subject, refreshToken: refreshToken)
    }
}

public struct AccountKey: Hashable, Sendable, Codable {
    public let tool: Tool
    /// `Identity.fileID`.
    public let id: String

    public init(tool: Tool, id: String) {
        self.tool = tool
        self.id = id
    }
}

public struct TokenSet: Sendable, Equatable {
    public let accessToken: String?
    public let accessTokenExpiry: Date?
    public let refreshToken: String?

    public init(accessToken: String?, accessTokenExpiry: Date?, refreshToken: String?) {
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.refreshToken = refreshToken
    }
}

/// The tokens in a live credential (the `LiveLogin.bytes` shape); nil when unparseable.
public func tokenSet(_ tool: Tool, bytes: Data) -> TokenSet? {
    switch tool {
    case .claude:
        guard let oauth = jsonObject(bytes)?["claudeAiOauth"] as? [String: Any] else { return nil }
        return TokenSet(accessToken: nonEmpty(oauth["accessToken"]),
                        accessTokenExpiry: (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                        refreshToken: nonEmpty(oauth["refreshToken"]))
    case .codex:
        guard let tokens = jsonObject(bytes)?["tokens"] as? [String: Any] else { return nil }
        let access = nonEmpty(tokens["access_token"])
        return TokenSet(accessToken: access,
                        accessTokenExpiry: access.flatMap(jwtClaims)?["exp"].flatMap { ($0 as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } },
                        refreshToken: nonEmpty(tokens["refresh_token"]))
    case .agy:
        guard case .object(let json)? = agyPayload(bytes), let token = json["token"] as? [String: Any] else { return nil }
        return TokenSet(accessToken: nonEmpty(token["access_token"]),
                        accessTokenExpiry: (token["expiry"] as? String).flatMap(parseRFC3339),
                        refreshToken: nonEmpty(token["refresh_token"]))
    }
}

/// What a tool is signed in as right now.
public struct LiveLogin: Sendable, Equatable {
    public let identity: Identity
    /// Claude `subscriptionType` · Codex `chatgpt_plan_type` · agy nil.
    public let plan: String?
    /// Email for display, "" when unknown.
    public let label: String
    /// The exact live credential: Claude/agy Keychain value (one trailing "\n" removed) · Codex `auth.json` bytes.
    public let bytes: Data
    public let tokens: TokenSet
    /// agy id_token `azp` (else `aud`) · otherwise nil.
    public let clientID: String?
    /// Claude: the exact bytes of the `oauthAccount` value in the config file · otherwise nil.
    public let claudeAccount: Data?
    /// Codex `chatgpt_account_id` · otherwise nil.
    public let accountID: String?

    public init(identity: Identity, plan: String?, label: String, bytes: Data, tokens: TokenSet,
                clientID: String?, claudeAccount: Data?, accountID: String?) {
        self.identity = identity
        self.plan = plan
        self.label = label
        self.bytes = bytes
        self.tokens = tokens
        self.clientID = clientID
        self.claudeAccount = claudeAccount
        self.accountID = accountID
    }
}

public enum LiveState: Sendable, Equatable {
    /// Complete or incomplete identity.
    case signedIn(LiveLogin)
    /// No item / no file.
    case notSignedIn
    /// Item or file present, token fields empty.
    case wiped
    /// Read failed or timed out, malformed recognised format, Claude pair mismatch.
    case unknown(String)
    /// Codex keyring / auto-with-item / ephemeral / unknown store mode, API-key login.
    case unsupported(String)

    public var allowsSwitch: Bool {
        switch self {
        case .unknown, .unsupported: false
        default: true
        }
    }

    public func statusText(_ tool: Tool) -> String? {
        switch self {
        case .signedIn: nil
        case .notSignedIn: "Not signed in"
        case .wiped: "Signed out"
        case .unknown: "\(tool.displayName)'s login can't be read right now — retry"
        case .unsupported: "Unsupported storage mode"
        }
    }
}

public protocol ToolAdapter: Sendable {
    var tool: Tool { get }
    func readLive() async -> LiveState
}

// MARK: - Parsing helpers shared by the tool adapters

func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func nonEmpty(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return s
}

/// A JWT's claims; base64url without padding, padded accepted.
func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    return Data(base64Encoded: b64).flatMap(jsonObject)
}

enum AgyPayload {
    case object([String: Any])
    case malformed
}

/// agy's Keychain value: a `go-keyring-base64:` (or `go-keyring-encoded:` hex) envelope around JSON, or bare JSON.
/// nil when the value is neither.
func agyPayload(_ bytes: Data) -> AgyPayload? {
    let text = String(decoding: bytes, as: UTF8.self)
    if text.hasPrefix("go-keyring-") {
        var decoded: Data?
        if text.hasPrefix("go-keyring-base64:") {
            decoded = Data(base64Encoded: String(text.dropFirst("go-keyring-base64:".count)))
        } else if text.hasPrefix("go-keyring-encoded:") {
            decoded = hexData(String(text.dropFirst("go-keyring-encoded:".count)))
        }
        return decoded.flatMap(jsonObject).map(AgyPayload.object) ?? .malformed
    }
    return jsonObject(bytes).map(AgyPayload.object)
}

func hexData(_ hex: String) -> Data? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out = Data(capacity: chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let byte = UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
        out.append(byte)
    }
    return out
}

/// RFC 3339 / ISO 8601 with any number of fractional digits and `Z` or `±hh:mm`.
func parseRFC3339(_ s: String) -> Date? {
    let pattern = /^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(?:([Zz])|([+-])([0-9]{2}):([0-9]{2}))$/
    guard let m = s.wholeMatch(of: pattern),
          let year = Int(m.1), let month = Int(m.2), let day = Int(m.3),
          let hour = Int(m.4), let minute = Int(m.5), let second = Int(m.6) else { return nil }
    var offset = 0
    if m.8 == nil {
        guard let sign = m.9, let oh = m.10.flatMap({ Int($0) }), let om = m.11.flatMap({ Int($0) }) else { return nil }
        offset = (sign == "-" ? -1 : 1) * (oh * 3600 + om * 60)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    guard let base = calendar.date(from: comps) else { return nil }
    let fraction = m.7.flatMap { Double("0." + $0) } ?? 0
    return base.addingTimeInterval(fraction - Double(offset))
}

/// Byte range of a top-level key's value in a JSON object's text, so a value can be read or replaced without
/// re-serializing the rest of the file.
func topLevelValueRange(of key: String, in data: Data) -> Range<Int>? {
    let b = [UInt8](data)
    var i = b.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0   // a UTF-8 BOM, which JSONSerialization accepts too
    func skipWS() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
    func skipString() -> Range<Int>? {
        guard i < b.count, b[i] == 0x22 else { return nil }
        let start = i
        i += 1
        while i < b.count {
            if b[i] == 0x5C { i += 2; continue }
            if b[i] == 0x22 { i += 1; return start..<i }
            i += 1
        }
        return nil
    }
    func skipValue() -> Bool {
        skipWS()
        guard i < b.count else { return false }
        if b[i] == 0x22 { return skipString() != nil }
        if b[i] == 0x7B || b[i] == 0x5B {
            var depth = 0
            while i < b.count {
                switch b[i] {
                case 0x22: if skipString() == nil { return false }; continue
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                default: break
                }
                i += 1
            }
            return false
        }
        while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        return true
    }
    skipWS()
    guard i < b.count, b[i] == 0x7B else { return nil }
    i += 1
    while true {
        skipWS()
        guard i < b.count, b[i] != 0x7D, let keyRange = skipString() else { return nil }
        let name = (try? JSONSerialization.jsonObject(with: Data(b[keyRange]), options: .fragmentsAllowed)) as? String
        skipWS()
        guard i < b.count, b[i] == 0x3A else { return nil }
        i += 1
        skipWS()
        let valueStart = i
        guard skipValue() else { return nil }
        if name == key { return valueStart..<i }
        skipWS()
        guard i < b.count, b[i] == 0x2C else { return nil }
        i += 1
    }
}
