import Foundation

/// Codex CLI: `auth.json` in `CODEX_HOME`, unless `config.toml` moves the login elsewhere.
public struct CodexTool: ToolAdapter {
    public let tool = Tool.codex
    let env: ToolEnvironment

    static let keyringService = "Codex Auth"

    public init(env: ToolEnvironment) {
        self.env = env
    }

    var authURL: URL { env.codexHome.appending(path: "auth.json") }

    /// Codex's own Keychain account for this `CODEX_HOME`.
    var keyringAccount: String {
        "cli|" + sha256Hex(Data(env.codexHome.resolvingSymlinksInPath().path.utf8)).prefix(16)
    }

    /// Top-level `cli_auth_credentials_store`; `file` when the file or key is absent.
    func storeMode() -> String {
        guard let text = try? String(contentsOf: env.codexHome.appending(path: "config.toml"), encoding: .utf8) else { return "file" }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if let m = trimmed.wholeMatch(of: /cli_auth_credentials_store\s*=\s*["']([^"']*)["']\s*(#.*)?/) {
                return String(m.1)
            }
        }
        return "file"
    }

    public func readLive() async -> LiveState {
        let mode = storeMode()
        switch mode {
        case "file":
            return readAuthFile()
        case "auto":
            switch await env.keychainClient.read(service: Self.keyringService, account: keyringAccount) {
            case .found: return .unsupported("Codex keeps this login in the Keychain")
            case .notFound: return readAuthFile()
            case .unknown(let reason): return .unknown(reason)
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
        guard json["auth_mode"] as? String == "chatgpt" else { return .unsupported("not a ChatGPT sign-in") }
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
