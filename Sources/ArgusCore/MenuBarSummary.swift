import Foundation
import Observation

public enum Severity: Sendable, Equatable { case normal, low }

public struct MenuBarValue: Sendable, Equatable {
    /// The share used, "38%", or "—".
    public let text: String
    /// Low when the shown integer is over 85; "—" is normal.
    public let severity: Severity

    public init(text: String, severity: Severity) {
        self.text = text
        self.severity = severity
    }

    static let missing = MenuBarValue(text: "—", severity: .normal)

    init(remaining: Double?) {
        guard let remaining else {
            self = .missing
            return
        }
        let used = Int((100 - remaining).rounded())
        self.init(text: "\(used)%", severity: used > 85 ? .low : .normal)
    }
}

public struct MenuBarSegment: Sendable, Equatable {
    public let tool: Tool
    public let letter: String
    /// An added context's name, drawn beside the tool's mark; nil for the default.
    public let context: String?
    public let sevenDay: MenuBarValue

    public init(tool: Tool, letter: String, context: String? = nil, sevenDay: MenuBarValue) {
        self.tool = tool
        self.letter = letter
        self.context = context
        self.sevenDay = sevenDay
    }
}

/// What the status item shows: per shown context with a live login, in tool order, the live account's 7 d used, the
/// highest across its groups.
public struct MenuBarSummary: Sendable, Equatable {
    public let segments: [MenuBarSegment]

    public var showsGlyphOnly: Bool { segments.isEmpty }

    public var accessibilityLabel: String {
        guard !segments.isEmpty else { return "Argus" }
        func spoken(_ value: MenuBarValue) -> String { value == .missing ? value.text : "\(value.text) used" }
        return segments.map { "\($0.tool.displayName)\($0.context.map { " (\($0))" } ?? "") 7 d \(spoken($0.sevenDay))" }.joined(separator: "; ")
    }

    public static func build(_ snapshots: [ToolSnapshot], isShown: (ToolContext) -> Bool) -> MenuBarSummary {
        let ordered = Tool.allCases.flatMap { tool in snapshots.filter { $0.tool == tool } }
        let segments = ordered.compactMap { snapshot -> MenuBarSegment? in
            guard isShown(snapshot.context), case .signedIn? = snapshot.live else { return nil }
            let live = snapshot.hidingMinorGroups.accounts.first(where: \.isLive)
            let groups = live?.reading?.groups ?? []
            return MenuBarSegment(tool: snapshot.tool, letter: snapshot.tool.letter, context: snapshot.context.isDefault ? nil : snapshot.context.name,
                                  sevenDay: MenuBarValue(remaining: groups.compactMap { $0.sevenDay?.remaining }.min()))
        }
        return MenuBarSummary(segments: segments)
    }
}

/// Each context's Show-in-menubar and Show-in-popover choices, persisted at once; on unless turned off.
@MainActor @Observable public final class MenuBarPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    /// Choices made since launch, by defaults key; the rest are read from the defaults.
    private var choices: [String: Bool] = [:]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func isInPopover(_ context: ToolContext) -> Bool { value(Self.popoverKey(context)) }
    public func setInPopover(_ context: ToolContext, _ on: Bool) { set(on, Self.popoverKey(context)) }
    public func isShown(_ context: ToolContext) -> Bool { value(Self.key(context)) }
    public func setShown(_ context: ToolContext, _ on: Bool) { set(on, Self.key(context)) }

    private func value(_ key: String) -> Bool { choices[key] ?? defaults.object(forKey: key) as? Bool ?? true }

    private func set(_ on: Bool, _ key: String) {
        choices[key] = on
        defaults.set(on, forKey: key)
    }

    static func key(_ context: ToolContext) -> String { "showInMenubar." + suffix(context) }
    static func popoverKey(_ context: ToolContext) -> String { "showInPopover." + suffix(context) }
    /// The tool, then an added context's path: a default context keeps the keys it had before contexts.
    private static func suffix(_ context: ToolContext) -> String { context.tool.rawValue + (context.path.map { ":" + $0 } ?? "") }
}
