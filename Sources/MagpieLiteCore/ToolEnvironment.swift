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
