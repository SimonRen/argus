import Foundation

/// Codex CLI: `auth.json` in `CODEX_HOME`, unless `config.toml` moves the login elsewhere.
public struct CodexTool: ToolAdapter {
    public let tool = Tool.codex
    let env: ToolEnvironment

    static let keyringService = "Codex Auth"
    /// The unsupported reason for a login with no refresh token (an API key): it can't share one with a saved account.
    static let apiKeyOnly = "an API-key sign-in"

    public init(env: ToolEnvironment) {
        self.env = env
    }

    public func scoped(to context: ToolContext) -> any ToolAdapter { CodexTool(env: env.scoped(to: context)) }

    var authURL: URL { env.liveCodexHome.appending(path: "auth.json") }

    /// Codex's own Keychain account for this `CODEX_HOME`.
    var keyringAccount: String {
        "cli|" + sha256Hex(Data(env.liveCodexHome.resolvingSymlinksInPath().path.utf8)).prefix(16)
    }

    /// Top-level `cli_auth_credentials_store`; `file` when the file or key is absent, nil when the file can't be read.
    func storeMode() -> String? {
        let url = env.liveCodexHome.appending(path: "config.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return "file" }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only a table header ends the top level; an array's own lines can start with "[" too.
            if trimmed.wholeMatch(of: /\[\[?[A-Za-z0-9_.\-"' ]+\]\]?\s*(#.*)?/) != nil { break }
            if let m = trimmed.wholeMatch(of: /cli_auth_credentials_store\s*=\s*["']([^"']*)["']\s*(#.*)?/) {
                return String(m.1)
            }
        }
        return "file"
    }

    public func readLive() async -> LiveState {
        guard let mode = storeMode() else { return .unknown("config.toml can't be read") }
        switch mode {
        case "file":
            return readAuthFile()
        case "auto":
            // Existence only: reading the secret would prompt, since the item trusts Codex, not `security`.
            switch await env.keychainClient.exists(service: Self.keyringService, account: keyringAccount) {
            case true?: return .unsupported("Codex keeps this login in the Keychain")
            case false?: return readAuthFile()
            case nil: return .unknown("the Keychain can't be read")
            }
        default:
            return .unsupported("Codex credential store \"\(mode)\"")
        }
    }

    func readAuthFile() -> LiveState {
        guard FileManager.default.fileExists(atPath: authURL.path) else { return .notSignedIn }
        guard let bytes = try? Data(contentsOf: authURL), let json = jsonObject(bytes) else {
            return .unknown("auth.json can't be parsed")
        }
        guard json["auth_mode"] as? String == "chatgpt" else {
            return .unsupported(tokenSet(.codex, bytes: bytes)?.refreshToken == nil ? Self.apiKeyOnly : "not a ChatGPT sign-in")
        }
        let tokens = tokenSet(.codex, bytes: bytes) ?? TokenSet(accessToken: nil, accessTokenExpiry: nil, refreshToken: nil)
        guard tokens.accessToken != nil || tokens.refreshToken != nil else { return .wiped }
        let tokenJSON = json["tokens"] as? [String: Any] ?? [:]
        let claims = nonEmpty(tokenJSON["id_token"]).flatMap(jwtClaims) ?? [:]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let accountID = nonEmpty(tokenJSON["account_id"]) ?? nonEmpty(auth["chatgpt_account_id"])
        let identity = Identity.codex(email: claims["email"] as? String, accountID: accountID, refreshToken: tokens.refreshToken)
        return .signedIn(LiveLogin(identity: identity, plan: nonEmpty(auth["chatgpt_plan_type"]), label: identity.email ?? "",
                                   bytes: bytes, tokens: tokens, clientID: nil, claudeAccount: nil, accountID: accountID))
    }
}
