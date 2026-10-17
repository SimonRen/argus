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
    /// The resolved `CODEX_HOME`.
    public var codexHome: URL
    /// Login name; picks Claude Code's Keychain account.
    public var user: String
    public var keychain: KeychainTarget
    public var security: any SecurityRunning

    public init(home: URL, codexHome: URL, user: String, keychain: KeychainTarget, security: any SecurityRunning) {
        self.home = home
        self.codexHome = codexHome
        self.user = user
        self.keychain = keychain
        self.security = security
    }

    var keychainClient: Keychain { Keychain(target: keychain, runner: security) }
}
