import Foundation

public struct ManagerSidebarRow: Sendable, Equatable {
    public let tool: Tool
    /// `MenuBarPreferences.isShown(context)`.
    public let showsMenubarGlyph: Bool
    public let liveEmail: String?
    /// The live account's highest 5 h and 7 d used across its groups, minor agy groups left out as in the menubar.
    public let fiveHour: MenuBarValue
    public let sevenDay: MenuBarValue

    public static func build(_ snapshot: ToolSnapshot, isShown: Bool) -> ManagerSidebarRow {
        let email: String? = if case .signedIn(let login)? = snapshot.live { login.label.isEmpty ? "Unknown account" : login.label } else { nil }
        let groups = email == nil ? [] : snapshot.hidingMinorGroups.accounts.first(where: \.isLive)?.reading?.groups ?? []
        func used(_ window: (AllowanceGroup) -> AllowanceWindow?) -> MenuBarValue {
            email == nil ? .missing : MenuBarValue(remaining: groups.compactMap { window($0)?.remaining }.min())
        }
        return ManagerSidebarRow(tool: snapshot.tool, showsMenubarGlyph: isShown, liveEmail: email,
                                 fiveHour: used(\.fiveHour), sevenDay: used(\.sevenDay))
    }
}

public enum ManagerText {
    public static func saveBanner(_ result: SaveResult) -> String { result.message }

    public static func header(_ snapshot: ToolSnapshot) -> String {
        guard case .signedIn(let login)? = snapshot.live else { return "Not signed in" }
        let email = login.label.isEmpty ? "Unknown account" : login.label
        let isSaved = snapshot.accounts.contains { $0.isSaved && $0.key.id == login.identity.fileID }
        return "Signed in as \(email)\(isSaved ? "" : " — not saved")"
    }

    /// A context row's status: its live login as last read. A named context without one hints that the variable must
    /// match the path exactly; one sharing its login with `sharedWith` (a copied folder) says what that costs.
    public static func contextStatus(_ live: LiveState?, context: ToolContext, sharedWith: ToolContext? = nil) -> String {
        switch live {
        case nil: return "Not read yet"
        case .signedIn(let login)? where !login.identity.isComplete:
            return "Signed in, but its account can't be read — " + paused(context.tool)
        case .signedIn(let login)?:
            let signedIn = "Signed in as \(login.label.isEmpty ? "Unknown account" : login.label)"
            guard let sharedWith else { return signedIn }
            return signedIn + " — the same login as \(sharedWith.name): whichever renews first signs the other out. Sign in again in one of them."
        case .notSignedIn? where !context.isDefault:
            return "Not signed in · \(context.tool == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR") must be exactly this path"
        case .unsupported(CodexTool.apiKeyOnly)?: return "Signed in with an API key, which Argus doesn't manage"
        case .unsupported?: return "Unsupported storage mode — " + paused(context.tool)
        case let state?: return state.statusText(context.tool) ?? ""
        }
    }

    /// Renewal waits while any context's login is unreadable: it might be a saved account's.
    private static func paused(_ tool: Tool) -> String {
        "saved \(tool.displayName) accounts aren't renewed meanwhile"
    }

    public static let emptyTitle = "No saved accounts"

    public static func emptyHint(_ tool: Tool) -> String {
        "Sign in with \(tool.displayName) as usual, then choose Save current login to keep it here."
    }
}
