import Foundation

/// Claude Code: its OAuth tokens in the Keychain, its account in the config file.
public struct ClaudeTool: ToolAdapter {
    public let tool = Tool.claude
    let env: ToolEnvironment

    static let service = "Claude Code-credentials"

    public init(env: ToolEnvironment) {
        self.env = env
    }

    var keychainAccount: String {
        env.user.wholeMatch(of: /[a-zA-Z0-9._-]+/) != nil ? env.user : "claude-code-user"
    }

    /// `.claude/.config.json` when it is a regular file with content, else `.claude.json`.
    var configURL: URL {
        let alternate = env.home.appending(path: ".claude/.config.json")
        let attrs = try? FileManager.default.attributesOfItem(atPath: alternate.resolvingSymlinksInPath().path)
        if attrs?[.type] as? FileAttributeType == .typeRegular, (attrs?[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            return alternate
        }
        return env.home.appending(path: ".claude.json")
    }

    /// The config's `oauthAccount`: parsed value and exact bytes.
    func readAccount() -> (value: [String: Any]?, bytes: Data?) {
        guard let data = try? Data(contentsOf: configURL),
              let range = topLevelValueRange(of: "oauthAccount", in: data) else { return (nil, nil) }
        let bytes = data.subdata(in: range)
        return ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], bytes)
    }

    public func readLive() async -> LiveState {
        let before = readAccount()
        let read = await env.keychainClient.read(service: Self.service, account: keychainAccount)
        let after = readAccount()
        let bytes: Data
        switch read {
        case .notFound: return .notSignedIn
        case .unknown(let reason): return .unknown(reason)
        case .found(let value): bytes = value
        }
        guard (before.value as NSDictionary?) == (after.value as NSDictionary?) else {
            return .unknown("the account changed while the login was read")
        }
        guard let json = jsonObject(bytes) else { return .unknown("the login is not a JSON object") }
        let oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
        let tokens = tokenSet(.claude, bytes: bytes) ?? TokenSet(accessToken: nil, accessTokenExpiry: nil, refreshToken: nil)
        guard tokens.accessToken != nil || tokens.refreshToken != nil else { return .wiped }
        let identity = Identity.claude(email: after.value?["emailAddress"] as? String,
                                       organizationUuid: after.value?["organizationUuid"] as? String,
                                       refreshToken: tokens.refreshToken)
        return .signedIn(LiveLogin(identity: identity, plan: nonEmpty(oauth["subscriptionType"]), label: identity.email ?? "",
                                   bytes: bytes, tokens: tokens, clientID: nil, claudeAccount: after.bytes, accountID: nil))
    }
}
