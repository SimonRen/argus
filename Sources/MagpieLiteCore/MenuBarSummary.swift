import Foundation
import Observation

public enum Severity: Sendable, Equatable { case normal, low }

public struct MenuBarValue: Sendable, Equatable {
    /// "62%" or "—".
    public let text: String
    /// Low when the shown integer is under 15; "—" is normal.
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
        let shown = Int(remaining.rounded())
        self.init(text: "\(shown)%", severity: shown < 15 ? .low : .normal)
    }
}

public struct MenuBarSegment: Sendable, Equatable {
    public let tool: Tool
    public let letter: String
    public let fiveHour: MenuBarValue
    public let sevenDay: MenuBarValue
    /// The live account's reading is stale.
    public let stale: Bool

    public init(tool: Tool, letter: String, fiveHour: MenuBarValue, sevenDay: MenuBarValue, stale: Bool) {
        self.tool = tool
        self.letter = letter
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.stale = stale
    }
}

/// What the status item shows: per shown tool with a live login, the live account's lowest 5 h and 7 d remaining.
public struct MenuBarSummary: Sendable, Equatable {
    public let segments: [MenuBarSegment]

    public var showsGlyphOnly: Bool { segments.isEmpty }

    public var accessibilityLabel: String {
        guard !segments.isEmpty else { return "Magpie Lite" }
        return segments.map { "\($0.tool.displayName) 5 h \($0.fiveHour.text), 7 d \($0.sevenDay.text)" }.joined(separator: "; ")
    }

    public static func build(_ snapshots: [ToolSnapshot], isShown: (Tool) -> Bool) -> MenuBarSummary {
        let segments = Tool.allCases.compactMap { tool -> MenuBarSegment? in
            guard isShown(tool), let snapshot = snapshots.first(where: { $0.tool == tool }), case .signedIn? = snapshot.live else { return nil }
            let live = snapshot.accounts.first(where: \.isLive)
            let groups = live?.reading?.groups ?? []
            return MenuBarSegment(tool: tool, letter: tool.letter,
                                  fiveHour: MenuBarValue(remaining: groups.compactMap { $0.fiveHour?.remaining }.min()),
                                  sevenDay: MenuBarValue(remaining: groups.compactMap { $0.sevenDay?.remaining }.min()),
                                  stale: live?.stale ?? false)
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
