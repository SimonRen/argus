import Foundation

/// Claude Code: its OAuth tokens in the Keychain, its account in the config file.
public struct ClaudeTool: ToolAdapter {
    public let tool = Tool.claude
    let env: ToolEnvironment

    static let service = "Claude Code-credentials"

    public init(env: ToolEnvironment) {
        self.env = env
    }

    public func scoped(to context: ToolContext) -> any ToolAdapter { ClaudeTool(env: env.scoped(to: context)) }

    /// The Keychain item: with `CLAUDE_CONFIG_DIR` set, suffixed with the first 8 hex of the SHA-256 of its exact value
    /// (NFC), as Claude Code names it; `~/.claude` set explicitly is a different item from the variable unset.
    var service: String {
        guard let dir = env.claudeConfigDir else { return Self.service }
        return Self.service + "-" + sha256Hex(Data(dir.precomposedStringWithCanonicalMapping.utf8)).prefix(8)
    }

    /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    var configHome: URL {
        env.claudeConfigDir.map { URL(fileURLWithPath: $0.precomposedStringWithCanonicalMapping, isDirectory: true) }
            ?? env.home.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// The user name when Claude Code accepts it as is (letters, digits, `.`, `_`, `-`); `claude-code-user` otherwise.
    var keychainAccount: String {
        env.user.wholeMatch(of: /[a-zA-Z0-9._-]+/) != nil ? env.user : "claude-code-user"
    }

    /// `.config.json` in the config home when it is a regular file with content, or an empty writable one while
    /// `.claude.json` is absent; else `.claude.json` (in `CLAUDE_CONFIG_DIR` when set, else the home folder).
    var configURL: URL {
        let fm = FileManager.default
        let alternate = configHome.appending(path: ".config.json")
        let primary = (env.claudeConfigDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? env.home).appending(path: ".claude.json")
        let path = alternate.resolvingSymlinksInPath().path
        let attrs = try? fm.attributesOfItem(atPath: path)
        guard attrs?[.type] as? FileAttributeType == .typeRegular else { return primary }
        if (attrs?[.size] as? NSNumber)?.intValue ?? 0 > 0 { return alternate }
        return fm.isWritableFile(atPath: path) && !fm.fileExists(atPath: primary.path) ? alternate : primary
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
        let read = await env.keychainClient.read(service: service, account: keychainAccount)
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
