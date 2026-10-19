import Foundation

/// A command-line tool whose saved logins the app manages. `allCases` is the display order.
public enum Tool: String, CaseIterable, Codable, Sendable, Hashable {
    case claude
    case codex
    case agy

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .agy: "Antigravity CLI"
        }
    }

    /// One-letter badge for compact layouts.
    public var letter: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .agy: "G"
        }
    }
}

/// Which keychain `security` addresses.
public enum KeychainTarget: Sendable, Equatable {
    /// The user's default keychain; only the app target constructs it.
    case login
    /// A keychain file; every test uses a disposable one.
    case file(URL)
}

/// Where a tool keeps its login on this Mac. The app target builds the live one; tests build theirs on temp folders.
public struct ToolEnvironment: Sendable {
    /// Stands for the user's home folder.
    public var home: URL
    /// The resolved `CODEX_HOME` of Codex's default context.
    public var codexHome: URL
    /// Login name; picks Claude Code's Keychain account.
    public var user: String
    public var keychain: KeychainTarget
    public var security: any SecurityRunning
    /// Each tool's context folder, exactly as its variable holds it; a tool absent here uses its default context.
    public private(set) var contextPaths: [Tool: String] = [:]

    public init(home: URL, codexHome: URL, user: String, keychain: KeychainTarget, security: any SecurityRunning) {
        self.home = home
        self.codexHome = codexHome
        self.user = user
        self.keychain = keychain
        self.security = security
    }

    var keychainClient: Keychain { Keychain(target: keychain, runner: security) }

    /// This environment pointed at `context` for its tool; the other tools keep theirs.
    public func scoped(to context: ToolContext) -> ToolEnvironment {
        var env = self
        env.contextPaths[context.tool] = context.path
        return env
    }

    /// `CLAUDE_CONFIG_DIR`; nil when unset.
    var claudeConfigDir: String? { contextPaths[.claude] }

    /// The Codex home in use: the context's folder, else `codexHome`.
    public var liveCodexHome: URL {
        contextPaths[.codex].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? codexHome
    }
}
