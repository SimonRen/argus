import CryptoKit
import Foundation
import Testing
import ArgusCore

fileprivate let claudeService = "Claude Code-credentials"
fileprivate let claudeItem = #"{"claudeAiOauth":{"accessToken":"test-access-1","refreshToken":"test-refresh-1","expiresAt":1790000000000,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{"srv":{"accessToken":"test-mcp-1"}}}"#
fileprivate let aliceAccount = #"{"emailAddress":"Alice@Example.com","accountUuid":"acc-1","organizationUuid":"org-1","organizationName":"Org","organizationRole":"admin","displayName":"Alice"}"#

fileprivate func claudeConfig(_ account: String?) -> String {
    let middle = account.map { "\"oauthAccount\": \($0),\n  " } ?? ""
    return "{\n  \"numStartups\": 3,\n  \(middle)\"theme\": \"dark\"\n}\n"
}

fileprivate func codexAuth(email: String, accountID: String?, claimAccount: String = "acct-claim", plan: String = "plus",
                           access: String = "test-access-1", refresh: String = "test-refresh-1", mode: String = "chatgpt") -> String {
    let idToken = testJWT(["email": email, "https://api.openai.com/auth": ["chatgpt_account_id": claimAccount, "chatgpt_plan_type": plan]])
    let accessToken = access.isEmpty ? "" : testJWT(["exp": 1_790_000_000, "tag": access])
    let account = accountID.map { ",\"account_id\":\"\($0)\"" } ?? ""
    return #"{"OPENAI_API_KEY":null,"auth_mode":"\#(mode)","tokens":{"id_token":"\#(idToken)","access_token":"\#(accessToken)","refresh_token":"\#(refresh)"\#(account)},"last_refresh":"2026-10-16T10:00:00Z"}"#
}

fileprivate func agyValue(_ json: String) -> String {
    "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
}

fileprivate func agyJSON(idToken: String?, inToken: Bool = false, access: String = "test-access-1", refresh: String = "test-refresh-1") -> String {
    let inner = inToken && idToken != nil ? #","id_token":"\#(idToken!)""# : ""
    let top = !inToken && idToken != nil ? #","id_token":"\#(idToken!)""# : ""
    return #"{"token":{"access_token":"\#(access)","token_type":"Bearer","refresh_token":"\#(refresh)","expiry":"2026-10-17T12:00:00.123456789+08:00"\#(inner)},"auth_method":"consumer"\#(top)}"#
}

/// Rewrites the Claude config while the Keychain item is being read.
fileprivate final class ConfigChangingSecurity: SecurityRunning, @unchecked Sendable {
    let inner: any SecurityRunning
    let change: @Sendable () -> Void
    init(inner: any SecurityRunning, change: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.change = change
    }
    func run(arguments: [String], stdin: Data?, timeout: Duration) async -> SecurityOutcome {
        if arguments.first == "find-generic-password" { change() }
        return await inner.run(arguments: arguments, stdin: stdin, timeout: timeout)
    }
}

@Suite struct LiveLoginTests {
    // MARK: Claude

    @Test func `REQ/F01-AC-1.c1 Claude identity is the lowercased email and organization, plan the subscription type`() async throws {
        let box = try TestSandbox()
        let config = claudeConfig(aliceAccount)
        try box.write("home/.claude.json", config)
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
        guard case .signedIn(let login) = await ClaudeTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity == .claude(email: "alice@example.com", organizationUuid: "org-1", refreshToken: "test-refresh-1"))
        #expect(login.identity.isComplete)
        #expect(login.identity.key == "claude:alice@example.com:org-1")
        #expect(login.plan == "max")
        #expect(login.label == "alice@example.com")
        #expect(login.bytes == utf8(claudeItem))
        #expect(login.claudeAccount == utf8(aliceAccount))
        #expect(login.tokens == TokenSet(accessToken: "test-access-1", accessTokenExpiry: Date(timeIntervalSince1970: 1_790_000_000), refreshToken: "test-refresh-1"))
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F01-AC-1.c1 Claude reads the account from .claude config.json when it has content`() async throws {
        let box = try TestSandbox()
        try box.write("home/.claude.json", claudeConfig(aliceAccount))
        try box.write("home/.claude/.config.json", claudeConfig(aliceAccount.replacingOccurrences(of: "Alice@Example.com", with: "other@example.com")))
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
        guard case .signedIn(let login) = await ClaudeTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity.email == "other@example.com")
    }

    @Test func `REQ/F01-AC-1.c1 Claude reads the Keychain under the login name when Claude Code accepts it, else claude-code-user`() async throws {
        for (user, account) in [("a.b_c-9", "a.b_c-9"), ("name with space", "claude-code-user"), ("o'neil", "claude-code-user"), ("", "claude-code-user")] {
            let box = try TestSandbox()
            var env = box.env
            env.user = user
            try box.write("home/.claude.json", claudeConfig(aliceAccount))
            #expect(await box.keychain.write(service: claudeService, account: account, value: utf8(claudeItem)) == .written)
            guard case .signedIn = await ClaudeTool(env: env).readLive() else { Issue.record("\(user.debugDescription) not signed in"); continue }
        }
    }

    @Test func `Claude takes an empty writable .claude config.json only while .claude.json is absent`() async throws {
        for primaryPresent in [false, true] {
            let box = try TestSandbox()
            try box.write("home/.claude/.config.json", "")
            if primaryPresent { try box.write("home/.claude.json", claudeConfig(aliceAccount)) }
            #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
            let state = await ClaudeTool(env: box.env).readLive()
            let email: String? = if case .signedIn(let login) = state { login.identity.email } else { nil }
            #expect((email != nil) == primaryPresent, "\(state)")
        }
    }

    @Test func `REQ/F01-AC-1.c6 a Claude item with empty access and refresh tokens shows signed out`() async throws {
        let box = try TestSandbox()
        try box.write("home/.claude.json", claudeConfig(aliceAccount))
        let wiped = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"scopes":[]},"mcpOAuth":{}}"#
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(wiped)) == .written)
        let state = await ClaudeTool(env: box.env).readLive()
        #expect(state == .wiped)
        #expect(state.statusText(.claude) == "Signed out")
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F01-AC-1.c8 a missing oauthAccount gives an incomplete identity that matches no saved account`() async throws {
        let box = try TestSandbox()
        try box.write("home/.claude.json", claudeConfig(nil))
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
        guard case .signedIn(let login) = await ClaudeTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(!login.identity.isComplete)
        #expect(login.identity.key == "claude:incomplete:" + sha256Hex(utf8("test-refresh-1")))
        #expect(login.claudeAccount == nil)
    }

    @Test func `REQ/F01-AC-1.c8 an oauthAccount without email or organization gives an incomplete identity`() async throws {
        let complete = Identity.claude(email: "alice@example.com", organizationUuid: "org-1", refreshToken: "test-refresh-1")
        for account in [#"{"organizationUuid":"org-1"}"#, #"{"emailAddress":"Alice@Example.com"}"#, #"{"emailAddress":"","organizationUuid":"org-1"}"#] {
            let box = try TestSandbox()
            try box.write("home/.claude.json", claudeConfig(account))
            #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
            guard case .signedIn(let login) = await ClaudeTool(env: box.env).readLive() else { Issue.record("not signed in"); continue }
            #expect(!login.identity.isComplete)
            #expect(login.identity != complete)
            #expect(login.identity.key != complete.key)
            #expect(login.identity.fileID != complete.fileID)
        }
    }

    @Test func `REQ/F01-AC-1.c10 an oauthAccount that changes during the Keychain read makes the live state unknown`() async throws {
        let box = try TestSandbox()
        let configURL = box.home.appending(path: ".claude.json")
        try box.write("home/.claude.json", claudeConfig(aliceAccount))
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
        let changed = claudeConfig(aliceAccount.replacingOccurrences(of: "org-1", with: "org-2"))
        let security = ConfigChangingSecurity(inner: box.env.security) { try? Data(changed.utf8).write(to: configURL) }
        var env = box.env
        env.security = security
        let state = await ClaudeTool(env: env).readLive()
        guard case .unknown = state else { Issue.record("read \(state)"); return }
        #expect(!state.allowsSwitch)
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F01-AC-1.c10 an oauthAccount rewritten with equal values during the read still reads signed in`() async throws {
        let box = try TestSandbox()
        let configURL = box.home.appending(path: ".claude.json")
        try box.write("home/.claude.json", claudeConfig(aliceAccount))
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
        let reformatted = "{\"oauthAccount\":{\"displayName\":\"Alice\",\"organizationUuid\":\"org-1\",\"emailAddress\":\"Alice@Example.com\",\"accountUuid\":\"acc-1\",\"organizationName\":\"Org\",\"organizationRole\":\"admin\"}}"
        let security = ConfigChangingSecurity(inner: box.env.security) { try? Data(reformatted.utf8).write(to: configURL) }
        var env = box.env
        env.security = security
        guard case .signedIn(let login) = await ClaudeTool(env: env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity.key == "claude:alice@example.com:org-1")
    }

    @Test func `Claude with no Keychain item is not signed in`() async throws {
        let box = try TestSandbox()
        try box.write("home/.claude.json", claudeConfig(aliceAccount))
        #expect(await ClaudeTool(env: box.env).readLive() == .notSignedIn)
        #expect(box.violations.isEmpty)
    }

    // MARK: Codex

    @Test func `REQ/F01-AC-1.c2 Codex identity is the lowercased id_token email and account id, plan the ChatGPT plan type`() async throws {
        let box = try TestSandbox()
        let auth = codexAuth(email: "Bob@Example.com", accountID: nil, claimAccount: "acct-1", plan: "plus")
        try box.write("codex/auth.json", auth)
        guard case .signedIn(let login) = await CodexTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity == .codex(email: "bob@example.com", accountID: "acct-1", refreshToken: "test-refresh-1"))
        #expect(login.identity.key == "codex:bob@example.com:acct-1")
        #expect(login.plan == "plus")
        #expect(login.accountID == "acct-1")
        #expect(login.label == "bob@example.com")
        #expect(login.bytes == utf8(auth))
        #expect(login.tokens.refreshToken == "test-refresh-1")
        #expect(login.tokens.accessTokenExpiry == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func `REQ/F01-AC-1.c2 Codex prefers tokens.account_id over the id_token claim`() async throws {
        let box = try TestSandbox()
        try box.write("codex/auth.json", codexAuth(email: "bob@example.com", accountID: "acct-file", claimAccount: "acct-claim"))
        guard case .signedIn(let login) = await CodexTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity.scope == "acct-file")
        #expect(login.accountID == "acct-file")
    }

    @Test func `REQ/F01-AC-1.c7 Codex keyring, ephemeral and unknown store modes show unsupported storage mode`() async throws {
        for mode in ["keyring", "ephemeral", "vault"] {
            let box = try TestSandbox()
            try box.write("codex/config.toml", "model = \"o3\"\ncli_auth_credentials_store = \"\(mode)\"\n\n[profiles.x]\nmodel = \"y\"\n")
            try box.write("codex/auth.json", codexAuth(email: "bob@example.com", accountID: "acct-1"))
            let state = await CodexTool(env: box.env).readLive()
            guard case .unsupported = state else { Issue.record("\(mode) read \(state)"); continue }
            #expect(state.statusText(.codex) == "Unsupported storage mode")
            #expect(!state.allowsSwitch)
        }
    }

    @Test func `REQ/F01-AC-1.c7 Codex auto mode with a Codex Auth item present shows unsupported storage mode`() async throws {
        let box = try TestSandbox()
        try box.write("codex/config.toml", "cli_auth_credentials_store = 'auto'\n")
        try box.write("codex/auth.json", codexAuth(email: "bob@example.com", accountID: "acct-1"))
        let account = "cli|" + sha256Hex(utf8(box.codexHome.resolvingSymlinksInPath().path)).prefix(16)
        #expect(await box.keychain.write(service: "Codex Auth", account: account, value: utf8("test-keyring-1")) == .written)
        let state = await CodexTool(env: box.env).readLive()
        guard case .unsupported = state else { Issue.record("read \(state)"); return }
        #expect(!state.allowsSwitch)
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F01-AC-1.c7 Codex auto mode without a Codex Auth item reads auth.json`() async throws {
        let box = try TestSandbox()
        try box.write("codex/config.toml", "cli_auth_credentials_store = \"auto\"\n")
        try box.write("codex/auth.json", codexAuth(email: "bob@example.com", accountID: "acct-1"))
        guard case .signedIn = await CodexTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(box.violations.isEmpty)
    }

    @Test func `Codex store mode after a multi-line array is still read, and an unreadable config is unknown`() async throws {
        let box = try TestSandbox()
        try box.write("codex/config.toml", "notify = [\n  [\"a\", \"b\"],\n  \"c\",\n]\ncli_auth_credentials_store = \"keyring\"\n")
        try box.write("codex/auth.json", codexAuth(email: "bob@example.com", accountID: "acct-1"))
        guard case .unsupported = await CodexTool(env: box.env).readLive() else { Issue.record("keyring mode missed"); return }
        let config = box.codexHome.appending(path: "config.toml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path) }
        guard case .unknown = await CodexTool(env: box.env).readLive() else { Issue.record("unreadable config not unknown"); return }
    }

    @Test func `Codex store mode under a table header is ignored`() async throws {
        let box = try TestSandbox()
        try box.write("codex/config.toml", "[profiles.x]\ncli_auth_credentials_store = \"keyring\"\n")
        try box.write("codex/auth.json", codexAuth(email: "bob@example.com", accountID: "acct-1"))
        guard case .signedIn = await CodexTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
    }

    @Test func `Codex missing, unparseable, API-key and wiped auth files`() async throws {
        let box = try TestSandbox()
        #expect(await CodexTool(env: box.env).readLive() == .notSignedIn)
        try box.write("codex/auth.json", "{not json")
        guard case .unknown = await CodexTool(env: box.env).readLive() else { Issue.record("expected unknown"); return }
        try box.write("codex/auth.json", #"{"OPENAI_API_KEY":"test-key-1","auth_mode":"apikey"}"#)
        guard case .unsupported = await CodexTool(env: box.env).readLive() else { Issue.record("expected unsupported"); return }
        try box.write("codex/auth.json", codexAuth(email: "bob@example.com", accountID: "acct-1", access: "", refresh: ""))
        #expect(await CodexTool(env: box.env).readLive() == .wiped)
    }

    // MARK: agy

    @Test func `REQ/F01-AC-1.c3 agy identity is the id_token sub with email as label`() async throws {
        let box = try TestSandbox()
        let idToken = testJWT(["sub": "sub-1", "email": "Carol@Example.com", "azp": "client-1", "aud": "aud-1"])
        let value = utf8(agyValue(agyJSON(idToken: idToken)))
        #expect(await box.keychain.write(service: "gemini", account: "antigravity", value: value) == .written)
        guard case .signedIn(let login) = await AgyTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity == .agy(subject: "sub-1", email: "carol@example.com", refreshToken: "test-refresh-1"))
        #expect(login.identity.key == "agy:sub-1")
        #expect(login.label == "carol@example.com")
        #expect(login.clientID == "client-1")
        #expect(login.plan == nil)
        #expect(login.bytes == value)
        #expect(abs(login.tokens.accessTokenExpiry!.timeIntervalSince1970 - 1_792_209_600.123456789) < 0.000_01)
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F01-AC-1.c3 agy reads an id_token kept inside token and falls back to aud`() async throws {
        let box = try TestSandbox()
        let idToken = testJWT(["sub": "sub-2", "email": "dave@example.com", "aud": "aud-2"])
        #expect(await box.keychain.write(service: "gemini", account: "antigravity", value: utf8(agyValue(agyJSON(idToken: idToken, inToken: true)))) == .written)
        guard case .signedIn(let login) = await AgyTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity.subject == "sub-2")
        #expect(login.clientID == "aud-2")
    }

    @Test func `REQ/F01-AC-1.c3 a malformed recognized envelope is unknown`() async throws {
        for value in ["go-keyring-base64:not-base64!", "go-keyring-encoded:7b", "go-keyring-base64:" + Data("[1,2]".utf8).base64EncodedString(), "deadbeef"] {
            let box = try TestSandbox()
            #expect(await box.keychain.write(service: "gemini", account: "antigravity", value: utf8(value)) == .written)
            let state = await AgyTool(env: box.env).readLive()
            guard case .unknown = state else { Issue.record("read \(state)"); continue }
            #expect(!state.allowsSwitch)
        }
    }

    @Test func `agy bare JSON, wiped and missing items`() async throws {
        let box = try TestSandbox()
        #expect(await AgyTool(env: box.env).readLive() == .notSignedIn)
        let idToken = testJWT(["sub": "sub-3"])
        #expect(await box.keychain.write(service: "gemini", account: "antigravity", value: utf8(agyJSON(idToken: idToken))) == .written)
        guard case .signedIn(let login) = await AgyTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.identity.subject == "sub-3")
        #expect(await box.keychain.write(service: "gemini", account: "antigravity", value: utf8(agyValue(agyJSON(idToken: idToken, access: "", refresh: "")))) == .written)
        #expect(await AgyTool(env: box.env).readLive() == .wiped)
        #expect(box.violations.isEmpty)
    }

    // MARK: Contexts

    /// Claude Code's item name for `CLAUDE_CONFIG_DIR=dir`, computed here independently of the app.
    private func contextService(_ dir: String) -> String {
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
        return claudeService + "-" + digest.prefix(8)
    }

    @Test func `REQ/F09-AC-9.c1 a Claude context reads the Keychain item named for its exact path and its own .claude.json`() async throws {
        let box = try TestSandbox()
        let dir = box.root.appending(path: "claude-work").path
        try box.write("claude-work/.claude.json", claudeConfig(aliceAccount))
        #expect(await box.keychain.write(service: contextService(dir), account: "tester", value: utf8(claudeItem)) == .written)
        let work = ToolContext(tool: .claude, path: dir, name: "work")
        guard case .signedIn(let login) = await ClaudeTool(env: box.env).scoped(to: work).readLive() else { Issue.record("context not signed in"); return }
        #expect(login.identity.key == "claude:alice@example.com:org-1")
        // The default context still reads the plain item and ~/.claude.json.
        #expect(await ClaudeTool(env: box.env).readLive() == .notSignedIn)
        #expect(await ClaudeTool(env: box.env).scoped(to: .default(.claude)).readLive() == .notSignedIn)
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F09-AC-9.c1 a trailing slash or an explicit ~ claude folder is another Claude login, and the path is NFC-normalised`() async throws {
        let box = try TestSandbox()
        try box.write("home/.claude.json", claudeConfig(aliceAccount))
        #expect(await box.keychain.write(service: claudeService, account: "tester", value: utf8(claudeItem)) == .written)
        let explicitDefault = ToolContext(tool: .claude, path: box.home.appending(path: ".claude").path, name: "explicit")
        try box.write("home/.claude/.claude.json", claudeConfig(aliceAccount))
        #expect(await ClaudeTool(env: box.env).scoped(to: explicitDefault).readLive() == .notSignedIn)

        let dir = box.root.appending(path: "work").path
        try box.write("work/.claude.json", claudeConfig(aliceAccount))
        #expect(await box.keychain.write(service: contextService(dir), account: "tester", value: utf8(claudeItem)) == .written)
        #expect(await ClaudeTool(env: box.env).scoped(to: ToolContext(tool: .claude, path: dir + "/", name: "slash")).readLive() == .notSignedIn)

        // "e" + combining acute names the same item as the precomposed "é".
        let composed = box.root.appending(path: "caf\u{E9}").path, decomposed = box.root.path + "/cafe\u{301}"
        try box.write("caf\u{E9}/.claude.json", claudeConfig(aliceAccount))
        #expect(await box.keychain.write(service: contextService(composed), account: "tester", value: utf8(claudeItem)) == .written)
        guard case .signedIn = await ClaudeTool(env: box.env).scoped(to: ToolContext(tool: .claude, path: decomposed, name: "nfd")).readLive() else {
            Issue.record("decomposed path missed the item"); return
        }
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F09-AC-9.c2 a Codex context reads auth.json in its own home and agy has one live login whatever the context`() async throws {
        let box = try TestSandbox()
        try box.write("codex-work/auth.json", codexAuth(email: "work@example.com", accountID: "acct-w"))
        let work = ToolContext(tool: .codex, path: box.root.appending(path: "codex-work").path, name: "work")
        guard case .signedIn(let login) = await CodexTool(env: box.env).scoped(to: work).readLive() else { Issue.record("context not signed in"); return }
        #expect(login.identity.key == "codex:work@example.com:acct-w")
        #expect(await CodexTool(env: box.env).readLive() == .notSignedIn)
        #expect(!Tool.agy.supportsContexts && Tool.claude.supportsContexts && Tool.codex.supportsContexts)
    }
}
