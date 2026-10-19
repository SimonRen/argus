import Foundation

/// One place a tool keeps its live login: Claude Code's `CLAUDE_CONFIG_DIR` or Codex's `CODEX_HOME`; the default is
/// the variable unset. Each context keeps its own list of saved logins; an account saved in several shares one reading.
/// Not `Identifiable`: `id` is unique within its tool only, so a list across tools would merge the default contexts.
public struct ToolContext: Codable, Sendable, Hashable {
    public let tool: Tool
    /// The variable's value exactly as the shell exports it; nil for the default. Claude Code names its Keychain item
    /// after these exact characters, so `/x` and `/x/` are two logins.
    public let path: String?
    public let name: String

    public init(tool: Tool, path: String?, name: String) {
        self.tool = tool
        self.path = path
        self.name = name
    }

    /// "" for the default, else the path: the context's key within its tool.
    public var id: String { path ?? "" }
    public var isDefault: Bool { path == nil }

    public static func `default`(_ tool: Tool) -> ToolContext { ToolContext(tool: tool, path: nil, name: "Default") }

    /// The variable to export for this context, e.g. `CLAUDE_CONFIG_DIR=/Users/me/.claude-work`; nil for the default.
    public var assignment: String? {
        guard let path else { return nil }
        return (tool == .codex ? "CODEX_HOME=" : "CLAUDE_CONFIG_DIR=") + path
    }
}

extension Tool {
    /// Claude Code and Codex can be pointed at another folder; agy has no setting for it.
    public var supportsContexts: Bool { self != .agy }
}
