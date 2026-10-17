import Foundation

public struct ManagerSidebarRow: Sendable, Equatable {
    public let tool: Tool
    /// `MenuBarPreferences.isShown(tool)`.
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
        let saved = snapshot.accounts.filter(\.isSaved).count
        guard case .signedIn(let login)? = snapshot.live else { return "Not signed in · \(saved) saved" }
        let email = login.label.isEmpty ? "Unknown account" : login.label
        let isSaved = snapshot.accounts.contains { $0.isSaved && $0.key.id == login.identity.fileID }
        return "Signed in as \(email)\(isSaved ? "" : " — not saved") · \(saved) saved"
    }

    public static let emptyTitle = "No saved accounts"

    public static func emptyHint(_ tool: Tool) -> String {
        "Sign in with \(tool.displayName) as usual, then choose Save current login to keep it here."
    }

    public static let footerHint = "To add an account, sign in with the tool itself — without signing out first — then choose Save current login."
}
