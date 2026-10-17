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
    public let fiveHour: MenuBarValue
    public let sevenDay: MenuBarValue

    public init(tool: Tool, letter: String, fiveHour: MenuBarValue, sevenDay: MenuBarValue) {
        self.tool = tool
        self.letter = letter
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// What the status item shows: per shown tool with a live login, the live account's 5 h and 7 d used, the highest across its groups.
public struct MenuBarSummary: Sendable, Equatable {
    public let segments: [MenuBarSegment]

    public var showsGlyphOnly: Bool { segments.isEmpty }

    public var accessibilityLabel: String {
        guard !segments.isEmpty else { return "Magpie Lite" }
        func spoken(_ value: MenuBarValue) -> String { value == .missing ? value.text : "\(value.text) used" }
        return segments.map { "\($0.tool.displayName) 5 h \(spoken($0.fiveHour)), 7 d \(spoken($0.sevenDay))" }.joined(separator: "; ")
    }

    public static func build(_ snapshots: [ToolSnapshot], isShown: (Tool) -> Bool) -> MenuBarSummary {
        let segments = Tool.allCases.compactMap { tool -> MenuBarSegment? in
            guard isShown(tool), let snapshot = snapshots.first(where: { $0.tool == tool })?.hidingMinorGroups, case .signedIn? = snapshot.live else { return nil }
            let live = snapshot.accounts.first(where: \.isLive)
            let groups = live?.reading?.groups ?? []
            return MenuBarSegment(tool: tool, letter: tool.letter,
                                  fiveHour: MenuBarValue(remaining: groups.compactMap { $0.fiveHour?.remaining }.min()),
                                  sevenDay: MenuBarValue(remaining: groups.compactMap { $0.sevenDay?.remaining }.min()))
        }
        return MenuBarSummary(segments: segments)
    }
}

/// Each tool's Show-in-menubar choice, persisted at once; on unless turned off.
@MainActor @Observable public final class MenuBarPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    private var shown: [Tool: Bool]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        shown = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, defaults.object(forKey: Self.key($0)) as? Bool ?? true) })
    }

    public func isShown(_ tool: Tool) -> Bool { shown[tool] ?? true }

    public func setShown(_ tool: Tool, _ on: Bool) {
        shown[tool] = on
        defaults.set(on, forKey: Self.key(tool))
    }

    static func key(_ tool: Tool) -> String { "showInMenubar.\(tool.rawValue)" }
}
