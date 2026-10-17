import Foundation
import Testing
import MagpieLiteCore

fileprivate let at = Date(timeIntervalSince1970: 1_790_000_000)

fileprivate func group(_ name: String, _ five: Double?, _ seven: Double?) -> AllowanceGroup {
    AllowanceGroup(name: name, fiveHour: five.map { AllowanceWindow(remaining: $0, resetsAt: nil) },
                   sevenDay: seven.map { AllowanceWindow(remaining: $0, resetsAt: nil) })
}

fileprivate func snapshot(_ tool: Tool, groups: [AllowanceGroup]?, stale: Bool = false, signedIn: Bool = true) -> ToolSnapshot {
    let login = testLogin(tool, "live")
    let account = AccountSnapshot(key: testKey(login), label: login.label, plan: nil, isLive: true, isSaved: true, kept: false, flag: .ok,
                                  reading: groups.map { AllowanceReading(groups: $0, plan: nil, fetchedAt: at) }, stale: stale)
    let other = AccountSnapshot(key: AccountKey(tool: tool, id: "other"), label: "o@example.com", plan: nil, isLive: false, isSaved: true,
                                kept: false, flag: .ok, reading: AllowanceReading(groups: [group("", 1, 1)], plan: nil, fetchedAt: at), stale: false)
    return ToolSnapshot(tool: tool, live: signedIn ? .signedIn(login) : .notSignedIn, accounts: [other, account], rateLimitedUntil: nil)
}

fileprivate func value(_ text: String, _ low: Bool = false) -> MenuBarValue { MenuBarValue(text: text, severity: low ? .low : .normal) }

@Suite struct MenuBarSummaryTests {
    // MARK: F05-AC-5.c1

    @Test func `REQ/F05-AC-5.c1 one segment per shown tool with a live login, in Claude, Codex, agy order`() {
        let snapshots = [snapshot(.agy, groups: [group("G", 45, 90)]), snapshot(.claude, groups: [group("All models", 62, 40)]),
                         snapshot(.codex, groups: [group("", 80, 71)])]
        let summary = MenuBarSummary.build(snapshots) { _ in true }
        #expect(summary.segments == [
            MenuBarSegment(tool: .claude, letter: "C", fiveHour: value("62%"), sevenDay: value("40%"), stale: false),
            MenuBarSegment(tool: .codex, letter: "X", fiveHour: value("80%"), sevenDay: value("71%"), stale: false),
            MenuBarSegment(tool: .agy, letter: "G", fiveHour: value("45%"), sevenDay: value("90%"), stale: false),
        ])
    }

    @Test func `REQ/F05-AC-5.c1 hidden tools and tools without a live login have no segment`() {
        let snapshots = [snapshot(.claude, groups: [group("", 1, 2)]), snapshot(.codex, groups: nil, signedIn: false), snapshot(.agy, groups: [group("", 3, 4)])]
        #expect(MenuBarSummary.build(snapshots) { $0 != .agy }.segments.map(\.tool) == [.claude])
    }

    @Test func `REQ/F05-AC-5.c1 a live login without a reading yet shows dashes`() {
        let summary = MenuBarSummary.build([snapshot(.codex, groups: nil)]) { _ in true }
        #expect(summary.segments.first?.fiveHour == value("—") && summary.segments.first?.sevenDay == value("—"))
    }

    // MARK: F05-AC-5.c2

    @Test func `REQ/F05-AC-5.c2 each window shows the lowest remaining across the live account's groups`() {
        let agy = MenuBarSummary.build([snapshot(.agy, groups: [group("Gemini", 45, 90), group("Claude and GPT", 30, 95)])]) { _ in true }
        #expect(agy.segments.first?.fiveHour == value("30%") && agy.segments.first?.sevenDay == value("90%"))
        let claude = MenuBarSummary.build([snapshot(.claude, groups: [group("All models", 62, 40), group("Fable", nil, 28)])]) { _ in true }
        #expect(claude.segments.first?.fiveHour == value("62%") && claude.segments.first?.sevenDay == value("28%"))
        let weekly = MenuBarSummary.build([snapshot(.codex, groups: [group("", nil, 54)])]) { _ in true }
        #expect(weekly.segments.first?.fiveHour == value("—") && weekly.segments.first?.sevenDay == value("54%"))
    }

    @Test func `REQ/F05-AC-5.c2 values round to whole percents`() {
        let summary = MenuBarSummary.build([snapshot(.agy, groups: [group("G", 95.45545, 14.5)])]) { _ in true }
        #expect(summary.segments.first?.fiveHour.text == "95%")
        #expect(summary.segments.first?.sevenDay.text == "15%")
    }

    // MARK: F05-AC-5.c3

    @Test func `REQ/F05-AC-5.c3 a shown value under 15 is low and anything else is normal`() {
        let cases: [(Double, Severity)] = [(0, .low), (14, .low), (14.4, .low), (14.5, .normal), (15, .normal), (39, .normal), (100, .normal)]
        for (remaining, severity) in cases {
            let summary = MenuBarSummary.build([snapshot(.claude, groups: [group("", remaining, nil)])]) { _ in true }
            #expect(summary.segments.first?.fiveHour.severity == severity)
            #expect(summary.segments.first?.sevenDay.severity == .normal)
        }
    }

    // MARK: F05-AC-5.c4

    @Test func `REQ/F05-AC-5.c4 only the stale tool's segment is marked stale and its low values stay low`() {
        let summary = MenuBarSummary.build([snapshot(.claude, groups: [group("", 10, 50)], stale: true), snapshot(.codex, groups: [group("", 80, 71)])]) { _ in true }
        #expect(summary.segments.map(\.stale) == [true, false])
        #expect(summary.segments.first?.fiveHour == value("10%", true))
    }

    // MARK: F05-AC-5.c5

    @Test func `REQ/F05-AC-5.c5 the spoken label names each segment's values`() {
        let summary = MenuBarSummary.build([snapshot(.claude, groups: [group("", 62, 40)]), snapshot(.codex, groups: [group("", 80, 71)])]) { _ in true }
        #expect(summary.accessibilityLabel == "Claude Code 5 h 62%, 7 d 40%; Codex 5 h 80%, 7 d 71%")
        #expect(!summary.showsGlyphOnly)
        let weekly = MenuBarSummary.build([snapshot(.agy, groups: [group("", nil, 54)])]) { _ in true }
        #expect(weekly.accessibilityLabel == "Antigravity CLI 5 h —, 7 d 54%")
    }

    // MARK: F05-AC-5.c7

    @Test func `REQ/F05-AC-5.c7 with no segment the item shows only the glyph and says Magpie Lite`() {
        let off = MenuBarSummary.build([snapshot(.claude, groups: [group("", 1, 2)])]) { _ in false }
        #expect(off.showsGlyphOnly && off.accessibilityLabel == "Magpie Lite")
        let signedOut = MenuBarSummary.build(Tool.allCases.map { snapshot($0, groups: nil, signedIn: false) }) { _ in true }
        #expect(signedOut.showsGlyphOnly && signedOut.accessibilityLabel == "Magpie Lite")
        #expect(MenuBarSummary.build([]) { _ in true }.showsGlyphOnly)
    }

    // MARK: F05-AC-5.c8

    @MainActor @Test func `REQ/F05-AC-5.c8 Show in menubar is on until set and a change survives a restart`() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = MenuBarPreferences(defaults: defaults)
        #expect(Tool.allCases.allSatisfy { prefs.isShown($0) })
        prefs.setShown(.agy, false)
        #expect(!prefs.isShown(.agy))
        #expect(defaults.object(forKey: "showInMenubar.agy") as? Bool == false)
        let restarted = MenuBarPreferences(defaults: UserDefaults(suiteName: suite)!)
        #expect(!restarted.isShown(.agy) && restarted.isShown(.claude) && restarted.isShown(.codex))
        restarted.setShown(.agy, true)
        #expect(MenuBarPreferences(defaults: UserDefaults(suiteName: suite)!).isShown(.agy))
    }
}
