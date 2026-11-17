import Foundation

public struct ManagerSidebarRow: Sendable, Equatable {
    public let tool: Tool
    public let liveEmail: String?
    /// The live account's window with the least left, minor agy groups left out as in the menubar; the earlier window on a tie.
    /// nil without a live login or a reading.
    public let tightest: WindowCell?

    public static func build(_ snapshot: ToolSnapshot) -> ManagerSidebarRow {
        let email: String? = if case .signedIn(let login)? = snapshot.live { login.label.isEmpty ? "Unknown account" : login.label } else { nil }
        // Only the labels and percentages are read, so the reset times' clock doesn't matter.
        let windows = email == nil ? [] : snapshot.hidingMinorGroups.accounts.first(where: \.isLive)
            .map { AccountRow($0, live: snapshot.live, pending: nil, now: .distantPast).windows } ?? []
        let tightest = windows.reduce(nil as WindowCell?) { best, cell in best.map { cell.fill > $0.fill ? cell : $0 } ?? cell }
        return ManagerSidebarRow(tool: snapshot.tool, liveEmail: email, tightest: tightest)
    }
}

public enum ManagerText {
    public static func saveBanner(_ result: SaveResult) -> String { result.message }

    public static func header(_ snapshot: ToolSnapshot) -> String {
        guard case .signedIn(let login)? = snapshot.live else { return "Not signed in" }
        let email = login.label.isEmpty ? "Unknown account" : login.label
        return "Signed in as \(email)\(isUnsaved(snapshot) ? " — not saved" : "")"
    }

    /// Signed in on a login with no saved copy: the header's "— not saved", and Save current login is the page's main action.
    public static func isUnsaved(_ snapshot: ToolSnapshot) -> Bool {
        guard case .signedIn(let login)? = snapshot.live else { return false }
        return !snapshot.accounts.contains { $0.isSaved && $0.key.id == login.identity.fileID }
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
            return "Not signed in · \(context.tool.contextVariable) must be exactly this path"
        case .unsupported(CodexTool.apiKeyOnly)?: return "Signed in with an API key, which Argus doesn't manage"
        case .unsupported?: return "Unsupported storage mode — " + paused(context.tool)
        case let state?: return state.statusText(context.tool) ?? ""
        }
    }

    /// Renewal waits while any context's login is unreadable: it might be a saved account's.
    private static func paused(_ tool: Tool) -> String {
        "saved \(tool.displayName) accounts aren't renewed meanwhile"
    }

    /// The context page's warning under its header: `contextStatus` when there is something to act on; nil when its login
    /// reads cleanly, or when the header's "Not signed in" already says it all.
    public static func contextWarning(_ live: LiveState?, context: ToolContext, sharedWith: ToolContext?) -> String? {
        switch live {
        case nil: return nil
        case .signedIn(let login)? where login.identity.isComplete && sharedWith == nil: return nil
        case .notSignedIn? where context.isDefault: return nil
        default: return contextStatus(live, context: context, sharedWith: sharedWith)
        }
    }

    /// A table column's title from its window label: "5h" → "5-hour used", "Fable 7d" → "Fable 7-day used".
    public static func columnTitle(_ label: String) -> String {
        var title = label
        if title.hasSuffix("5h") { title = title.dropLast(2) + "5-hour" } else if title.hasSuffix("7d") { title = title.dropLast(2) + "7-day" }
        return title + " used"
    }

    public static func emptyHint(_ tool: Tool) -> String {
        "Sign in with \(tool.displayName) as usual, then choose Save current login to keep it here."
    }
}
