import Foundation

/// Antigravity CLI: a go-keyring item in the Keychain.
public struct AgyTool: ToolAdapter {
    public let tool = Tool.agy
    let env: ToolEnvironment

    static let service = "gemini"
    static let account = "antigravity"

    public init(env: ToolEnvironment) {
        self.env = env
    }

    public func readLive() async -> LiveState {
        let bytes: Data
        switch await env.keychainClient.read(service: Self.service, account: Self.account) {
        case .notFound: return .notSignedIn
        case .unknown(let reason): return .unknown(reason)
        case .found(let value): bytes = value
        }
        let json: [String: Any]
        switch agyPayload(bytes) {
        case nil: return .unknown("the login is not in a recognised format")
        case .malformed: return .unknown("the login envelope is malformed")
        case .object(let object): json = object
        }
        let token = json["token"] as? [String: Any] ?? [:]
        let tokens = tokenSet(.agy, bytes: bytes) ?? TokenSet(accessToken: nil, accessTokenExpiry: nil, refreshToken: nil)
        guard tokens.accessToken != nil || tokens.refreshToken != nil else { return .wiped }
        let claims = (nonEmpty(json["id_token"]) ?? nonEmpty(token["id_token"])).flatMap(jwtClaims) ?? [:]
        // agy 1.4.9 writes `id_token_email` and no id_token, so no `azp` either: it signs in with its own embedded client.
        let email = nonEmpty(claims["email"]) ?? nonEmpty(json["id_token_email"])
        let identity = Identity.agy(subject: claims["sub"] as? String, email: email, refreshToken: tokens.refreshToken)
        let clientID = nonEmpty(claims["azp"]) ?? nonEmpty(claims["aud"]) ?? (claims.isEmpty ? OAuthClients.antigravityClientID : nil)
        return .signedIn(LiveLogin(identity: identity, plan: nil, label: identity.email ?? "", bytes: bytes, tokens: tokens,
                                   clientID: clientID, claudeAccount: nil, accountID: nil))
    }
}
