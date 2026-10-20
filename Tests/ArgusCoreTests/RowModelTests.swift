import Foundation
import Testing
import ArgusCore

fileprivate let now = Date(timeIntervalSince1970: 1_790_000_000)

fileprivate func reading(_ groups: [(String, Double?, Double?)], at: Date = now, resets: Date? = nil) -> AllowanceReading {
    AllowanceReading(groups: groups.map { g in
        AllowanceGroup(name: g.0, fiveHour: g.1.map { AllowanceWindow(remaining: $0, resetsAt: resets) },
                       sevenDay: g.2.map { AllowanceWindow(remaining: $0, resetsAt: resets) })
    }, plan: nil, fetchedAt: at)
}

fileprivate func account(_ email: String, id: String? = nil, live: Bool = false, saved: Bool = true, kept: Bool = false, flag: AccountFlag = .ok,
                         reading: AllowanceReading? = nil, stale: Bool = false, tool: Tool = .claude) -> AccountSnapshot {
    AccountSnapshot(key: AccountKey(tool: tool, id: id ?? email), label: email, plan: "Pro", isLive: live, isSaved: saved, kept: kept,
                    flag: flag, reading: reading, stale: stale)
}

fileprivate func snapshot(_ accounts: [AccountSnapshot], live: LiveState? = .signedIn(testLogin(.claude, "live")), tool: Tool = .claude,
                          until: Date? = nil) -> ToolSnapshot {
    ToolSnapshot(tool: tool, live: live, accounts: accounts, rateLimitedUntil: until)
}

fileprivate func card(_ s: ToolSnapshot, expanded: Bool = false) -> ToolCard {
    ToolCard.build(s, expanded: expanded, dismissedUnsavedKey: nil, now: now)
}

@Suite struct RowModelTests {
    @Test func `the popover leaves out agy's Claude and GPT group, the manager keeps it, and other tools are untouched`() {
        let groups = reading([("Gemini", 45, 90), ("Claude and GPT", 0, 0)])
        let agy = snapshot([account("g@example.com", live: true, reading: groups, tool: .agy),
                            account("h@example.com", reading: groups, tool: .agy)], live: .signedIn(testLogin(.agy, "g")), tool: .agy)
        let popover = card(agy.hidingMinorGroups, expanded: true)
        #expect(popover.liveRow?.groups.map(\.name) == ["Gemini"] && popover.liveRow?.groups.first?.sevenDay.percentText == "10%")
        #expect(popover.others.first?.groups.count == 1)
        #expect(card(agy, expanded: true).liveRow?.groups.map(\.name) == ["Gemini", "Claude and GPT"])
        let claude = snapshot([account("c@example.com", live: true, reading: reading([("All models", 50, 50), ("Claude Fable", nil, 40)]))])
        #expect(claude.hidingMinorGroups == claude)
    }

    // MARK: F06-AC-6.c2

    @Test func `REQ/F06-AC-6.c2 a card shows its live row and +N more, and expanded lists the others by email`() {
        let accounts = [account("zed@example.com"), account("Bob@example.com", id: "b2"), account("bob@example.com", id: "b1"),
                        account("live@example.com", live: true), account("amy@example.com")]
        let collapsed = card(snapshot(accounts))
        #expect(collapsed.liveRow?.email == "live@example.com" && collapsed.liveRow?.isLive == true)
        #expect(collapsed.liveRow?.plan == "PRO")
        #expect(collapsed.moreLabel == "+4 more")
        #expect(collapsed.others.map(\.id.id) == ["amy@example.com", "b1", "b2", "zed@example.com"])
        #expect(card(snapshot(accounts), expanded: true).moreLabel == "Live only")
        #expect(card(snapshot([account("live@example.com", live: true)])).moreLabel == nil)
    }

    @Test func `the expanded list keeps its order across a switch, only the live mark moves`() {
        let before = card(snapshot([account("zed@example.com"), account("amy@example.com", live: true), account("bob@example.com")]), expanded: true)
        let after = card(snapshot([account("zed@example.com", live: true), account("amy@example.com"), account("bob@example.com")]), expanded: true)
        let order = ["amy@example.com", "bob@example.com", "zed@example.com"]
        #expect(before.rows.map(\.id.id) == order && after.rows.map(\.id.id) == order)
        #expect(before.rows.map(\.isLive) == [true, false, false] && after.rows.map(\.isLive) == [false, false, true])
        #expect(after.liveRow?.id.id == "zed@example.com" && after.others.map(\.id.id) == ["amy@example.com", "bob@example.com"])
    }

    @Test func `REQ/F06-AC-6.c2 a tool that is not signed in shows its status instead of a live row`() {
        let c = card(snapshot([account("a@example.com")], live: .notSignedIn))
        #expect(c.liveRow == nil && c.liveStatusText == "Not signed in" && c.moreLabel == "+1 more")
        #expect(card(snapshot([], live: .wiped)).liveStatusText == "Signed out")
        #expect(card(snapshot([], live: .unknown("x"))).liveStatusText == "Claude Code's login can't be read right now — retry")
        #expect(card(snapshot([], live: .unsupported("x"), tool: .codex)).liveStatusText == "Unsupported storage mode")
        #expect(card(snapshot([account("live@example.com", live: true)])).liveStatusText == nil)
    }

    // MARK: F06-AC-6.c4

    @Test func `REQ/F06-AC-6.c4 each state shows on its row in order: stale age, blocked state, kept`() {
        let stale = AccountRowProbe(account("s@example.com", kept: true, flag: .needsSignIn, reading: reading([("", 50, 50)], at: now - 1080), stale: true))
        #expect(stale.row.badges == [.stale("18 min ago"), .needsSignIn, .kept])
        for (flag, badge) in [(AccountFlag.appNeedsUpdate, RowBadge.appNeedsUpdate), (.incomplete, .incomplete), (.unreadable, .unreadable)] {
            #expect(AccountRowProbe(account("x@example.com", flag: flag)).row.badges == [badge])
        }
        let staleWithoutReading = AccountRowProbe(account("n@example.com", stale: true))
        #expect(staleWithoutReading.row.badges == [.notFetched])
        #expect(AccountRowProbe(account("z@example.com", flag: .needsSignIn, stale: true)).row.badges == [.needsSignIn])
        #expect(AccountRowProbe(account("", flag: .unreadable)).row.email == "Unknown account")
    }

    // MARK: F03-AC-3.c12

    @Test func `REQ/F03-AC-3.c12 blocked accounts disable Switch with their reason and non-live refresh`() {
        let cases: [(AccountFlag, String)] = [(.needsSignIn, "Needs sign-in"), (.appNeedsUpdate, "App needs update"),
                                              (.incomplete, "Incomplete identity"), (.unreadable, "Unreadable vault entry")]
        for (flag, reason) in cases {
            let row = AccountRowProbe(account("x@example.com", flag: flag)).row
            #expect(row.switchDisabledReason == reason)
            #expect(!row.refreshEnabled)
        }
        let ok = AccountRowProbe(account("ok@example.com")).row
        #expect(ok.switchDisabledReason == nil && ok.refreshEnabled)
        #expect(AccountRowProbe(account("live@example.com", live: true, flag: .needsSignIn)).row.refreshEnabled)
    }

    @Test func `REQ/F03-AC-3.c12 an unreadable live login disables every Switch with its status`() {
        let c = card(snapshot([account("a@example.com"), account("b@example.com")], live: .unknown("timed out")))
        #expect(c.others.allSatisfy { $0.switchDisabledReason == "Claude Code's login can't be read right now — retry" })
    }

    // MARK: F06-AC-6.c6

    @Test func `an action under way in a context names itself on its row and holds the context's other Switch and Remove buttons`() {
        let accounts = [account("amy@example.com", live: true), account("bob@example.com"), account("cid@example.com", flag: .needsSignIn)]
        let bob = AccountKey(tool: .claude, id: "bob@example.com")
        func build(_ pending: PendingAction?) -> ToolCard {
            ToolCard.build(snapshot(accounts), expanded: true, dismissedUnsavedKey: nil, pending: pending, now: now)
        }
        let idle = build(nil)
        #expect(idle.pending == nil && idle.rows.allSatisfy { $0.activity == nil && $0.removeEnabled })
        #expect(idle.rows.map(\.switchDisabledReason) == [nil, nil, "Needs sign-in"])
        let switching = build(.switching(bob))
        #expect(switching.pending == .switching(bob))
        #expect(switching.rows.map(\.activity) == [nil, .switching(bob), nil])
        #expect(switching.rows.map(\.switchDisabledReason) == ["Switching…", "Switching…", "Needs sign-in"])
        #expect(switching.rows.allSatisfy { !$0.removeEnabled })
        // However it ended, the switch stays on its row and the other Switch buttons stay held until it settles.
        for (ok, text) in [(true, "Switched"), (false, "Not switched")] {
            let ended = build(.switched(bob, ok: ok))
            #expect(ended.rows.map(\.activity) == [nil, .switched(bob, ok: ok), nil])
            #expect(ended.rows.map(\.switchDisabledReason) == [text, text, "Needs sign-in"])
        }
        #expect(build(.removing(bob)).rows.map(\.activity?.text) == [nil, "Removing…", nil])
        #expect(build(.saving).rows.allSatisfy { $0.activity == nil && !$0.removeEnabled })
    }

    @Test func `REQ/F06-AC-6.c6 the live row suggests the best other account when it runs low`() {
        let accounts = [account("live@example.com", live: true, reading: reading([("All models", 12, 50), ("Fable", nil, 60)])),
                        account("good@example.com", reading: reading([("All models", 80, 45)])),
                        account("best@example.com", reading: reading([("All models", 90, 70)])),
                        account("tie@example.com", reading: reading([("All models", 70, 90)]))]
        let c = card(snapshot(accounts))
        #expect(c.suggestion == Suggestion(target: AccountKey(tool: .claude, id: "best@example.com"), text: "Running low. best@example.com has used 30%."))
    }

    @Test func `a stale or unfetched row's tooltip says why: a backoff with its next try, else the error`() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 1_789_999_200)   // 14:00 UTC
        #expect(PopoverText.problem(tool: .claude, error: "rate limited", retryAt: at, now: at - 600, timeZone: utc) == "Rate limited by Claude. Next try at 14:00.")
        #expect(PopoverText.problem(tool: .claude, error: "rate limited", retryAt: at, now: at + 1, timeZone: utc) == "Couldn't refresh: rate limited.")
        #expect(PopoverText.problem(tool: .codex, error: "HTTP 503: busy", retryAt: nil, now: at, timeZone: utc) == "Couldn't refresh: HTTP 503: busy.")
        #expect(PopoverText.problem(tool: .agy, error: nil, retryAt: nil, now: at, timeZone: utc) == "Not refreshed this time.")
        #expect(RowBadge.notFetched.isFetchProblem && RowBadge.stale("1 min ago").isFetchProblem && !RowBadge.needsSignIn.isFetchProblem)
    }

    @Test func `a window with nothing used reads not started, even with a reset time`() {
        #expect(PopoverText.resetText(AllowanceWindow(remaining: 100, resetsAt: now + 18000), now: now) == "not started")
        #expect(PopoverText.resetText(AllowanceWindow(remaining: 99.6, resetsAt: now + 18000), now: now) == "5h 00m")
    }

    @Test func `REQ/F06-AC-6.c6 ties go to the first account in list order`() {
        let accounts = [account("live@example.com", live: true, reading: reading([("", 5, 50)])),
                        account("b@example.com", reading: reading([("", 60, 60)])), account("a@example.com", reading: reading([("", 60, 60)]))]
        #expect(card(snapshot(accounts)).suggestion?.target.id == "a@example.com")
    }

    @Test func `REQ/F06-AC-6.c6 no suggestion without a low fresh live score or a fresh healthy alternative`() {
        let healthy = account("h@example.com", reading: reading([("", 90, 90)]))
        let cases: [[AccountSnapshot]] = [
            [account("l@example.com", live: true, reading: reading([("", 20, 50)])), healthy],
            [account("l@example.com", live: true, reading: reading([("", 5, 50)]), stale: true), healthy],
            [account("l@example.com", live: true, reading: reading([("", nil, nil)])), healthy],
            [account("l@example.com", live: true), healthy],
            [account("l@example.com", live: true, reading: reading([("", 5, 50)])), account("x@example.com", reading: reading([("", 39, 90)]))],
            [account("l@example.com", live: true, reading: reading([("", 5, 50)])), account("x@example.com", reading: reading([("", 90, 90)]), stale: true)],
            [account("l@example.com", live: true, reading: reading([("", 5, 50)])), account("x@example.com", flag: .needsSignIn, reading: reading([("", 90, 90)]))],
            [account("l@example.com", live: true, reading: reading([("", 5, 50)])), account("x@example.com", saved: false, reading: reading([("", 90, 90)]))],
        ]
        for accounts in cases { #expect(card(snapshot(accounts)).suggestion == nil) }
    }

    // MARK: F06-AC-6.c7

    @Test func `REQ/F06-AC-6.c7 reset texts`() {
        func text(_ seconds: TimeInterval, remaining: Double = 50) -> String {
            PopoverText.resetText(AllowanceWindow(remaining: remaining, resetsAt: now + seconds), now: now)
        }
        #expect(text(48 * 60) == "48m")
        #expect(text(2 * 3600 + 14 * 60) == "2h 14m")
        #expect(text(4 * 3600 + 2 * 60) == "4h 02m")
        #expect(text(6 * 86400 + 18 * 3600) == "6d 18h")
        #expect(PopoverText.resetText(AllowanceWindow(remaining: 100, resetsAt: nil), now: now) == "not started")
        #expect(PopoverText.resetText(AllowanceWindow(remaining: 60, resetsAt: nil), now: now) == "—")
        #expect(PopoverText.resetText(nil, now: now) == "—")
        let weekly = AccountRowProbe(account("w@example.com", reading: reading([("", nil, 54)], resets: now + 3600))).row
        #expect(weekly.groups[0].fiveHour.resetText == "none")
        #expect(weekly.groups[0].sevenDay.resetText == "1h 00m")
    }

    // MARK: F06-AC-6.c8

    @Test func `REQ/F06-AC-6.c8 bands follow the remaining share, text and fill show the share used, and a missing window is an empty track`() {
        #expect([100, 40, 39.6, 39.4, 15, 14.6, 14.4, 0].map(band) == [.ok, .ok, .ok, .warn, .warn, .warn, .low, .low])
        #expect(band(nil) == .empty)
        let row = AccountRowProbe(account("x@example.com", reading: reading([("", nil, 62)]))).row
        #expect(row.groups[0].fiveHour == WindowCell(label: "5h", percentText: "—", band: .empty, resetText: "none", fill: 0))
        #expect(row.groups[0].sevenDay.percentText == "38%" && row.groups[0].sevenDay.band == .ok && row.groups[0].sevenDay.fill == 0.38)
        let none = AccountRowProbe(account("y@example.com")).row
        #expect(none.groups.count == 1 && none.groups[0].fiveHour.band == .empty && none.groups[0].sevenDay.percentText == "—")
    }

    // MARK: F06-AC-6.c9

    @Test func `REQ/F06-AC-6.c9 group names show when an account has more than one group, and always for agy`() {
        let two = AccountRowProbe(account("x@example.com", reading: reading([("Gemini", 45, 90), ("Claude & GPT", 30, 95)]))).row
        #expect(two.groups.map(\.name) == ["Gemini", "Claude & GPT"])
        let one = AccountRowProbe(account("y@example.com", reading: reading([("All models", 62, 40)]))).row
        #expect(one.groups.map(\.name) == [nil])
        #expect(AccountRowProbe(account("g@example.com", reading: reading([("Gemini", 45, 90)]), tool: .agy)).row.groups.map(\.name) == ["Gemini"])
        #expect(AccountRowProbe(account("u@example.com", reading: reading([("", 45, 90)]), tool: .agy)).row.groups.map(\.name) == [nil])
    }

    @Test func `popover table columns come from every row, the first group plain and later ones named against it`() {
        func labels(_ groups: [(String, Double?, Double?)], _ tool: Tool) -> [String] {
            AccountRowProbe(account("x@example.com", reading: reading(groups), tool: tool)).row.windows.map(\.label)
        }
        #expect(labels([("All models", 84, 9), ("Fable", nil, 80)], .claude) == ["5h", "7d", "Fable 7d"])
        #expect(labels([("", 45, 90)], .codex) == ["5h", "7d"])
        #expect(labels([("Gemini", 45, 90), ("Gemini 4 Argon", nil, 76)], .agy) == ["5h", "7d", "Argon 7d"])
        #expect(labels([("Gemini", 45, 90)], .agy) == ["5h", "7d"])
        #expect(labels([("Gemini", 45, 90), ("Claude & GPT", nil, 95)], .agy) == ["5h", "7d", "Claude & GPT 7d"])
        let pro = account("a@example.com", live: true, reading: reading([("All models", 84, 9)]))
        let maxPlan = account("b@example.com", reading: reading([("All models", 50, 50), ("Fable", nil, 80)]))
        let claude = card(snapshot([pro, maxPlan, account("c@example.com")]))
        #expect(claude.columns == ["5h", "7d", "Fable 7d"])
        #expect(claude.liveRow?.cells(claude.columns).map(\.resetText).last == "none")
        #expect(claude.rows.first { $0.email == "c@example.com" }?.cells(claude.columns).map(\.percentText) == ["—", "—", "—"])
        #expect(card(snapshot([account("w@example.com", live: true, reading: reading([("", nil, 54)]))])).columns == ["7d"])
        #expect(card(snapshot([account("u@example.com", live: true)])).columns == ["5h", "7d"])
    }

    @Test func `a blocked or never-fetched popover row spans the columns with one box, only Kept stays beside the plan and a stale age shows in the manager only`() {
        let fresh = AccountRowProbe(account("f@example.com", reading: reading([("", 50, 50)]))).row
        #expect(fresh.banner == nil && fresh.inlineBadges.isEmpty)
        #expect(AccountRowProbe(account("n@example.com")).row.banner == .notFetched)
        let unfetched = AccountRowProbe(account("u@example.com", stale: true)).row
        #expect(unfetched.banner == .notFetched && unfetched.inlineBadges.isEmpty && unfetched.badges == [.notFetched])
        let blocked = AccountRowProbe(account("s@example.com", kept: true, flag: .needsSignIn, reading: reading([("", 50, 50)]))).row
        #expect(blocked.banner == .blocked("Needs sign-in") && blocked.inlineBadges == [.kept])
        let stale = AccountRowProbe(account("o@example.com", reading: reading([("", 50, 50)], at: now - 120), stale: true)).row
        #expect(stale.banner == nil && stale.inlineBadges.isEmpty && stale.badges == [.stale("2 min ago")])
    }

    @Test func `the popover row shows the email before its @, and the plan with live under it`() {
        let live = AccountRowProbe(account("jmulro@gmail.com", live: true)).row
        #expect(live.name == "jmulro" && live.email == "jmulro@gmail.com" && live.subtitle == "Pro · live")
        #expect(AccountRowProbe(account("other@gmail.com")).row.subtitle == "Pro")
        #expect(AccountRowProbe(account("")).row.name == "Unknown account")
        #expect(AccountRowProbe(account("@example.com")).row.name == "@example.com")
    }

    // MARK: F06-AC-6.c11

    @Test func `REQ/F06-AC-6.c11 the refresh hint says when to try again, naming a rate-limiting vendor`() {
        let utc = TimeZone(identifier: "UTC")!
        let until = Date(timeIntervalSince1970: 1_789_999_200)   // 14:00 UTC
        #expect(PopoverText.refreshHint(RefreshDeferral(until: until, rateLimitedBy: nil), now: until - 47.2, timeZone: utc)
                == "Refreshed moments ago. Try again in 48 s.")
        #expect(PopoverText.refreshHint(RefreshDeferral(until: until, rateLimitedBy: nil), now: until, timeZone: utc)
                == "Refreshed moments ago. Try again in 1 s.")
        #expect(PopoverText.refreshHint(RefreshDeferral(until: until, rateLimitedBy: nil), now: until - 168, timeZone: utc)
                == "Refreshed moments ago. Try again in 3 min.")
        #expect(PopoverText.refreshHint(RefreshDeferral(until: until, rateLimitedBy: .claude), now: until - 300, timeZone: utc)
                == "Claude is rate-limited. Next check at 14:00.")
        #expect(PopoverText.refreshHint(RefreshDeferral(until: until, rateLimitedBy: .codex), now: until - 300, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
                == "Codex is rate-limited. Next check at 22:00.")
    }

    // MARK: F06-AC-6.c12

    @Test func `REQ/F06-AC-6.c12 the subtitle reads the age of the last live fetch and the interval`() {
        #expect(PopoverText.subtitle(lastLiveFetch: now - 20, intervalMinutes: 5, now: now) == "Live updated just now · every 5 min")
        #expect(PopoverText.subtitle(lastLiveFetch: now - 180, intervalMinutes: 3, now: now) == "Live updated 3 min ago · every 3 min")
        #expect(PopoverText.subtitle(lastLiveFetch: now - 7200, intervalMinutes: 10, now: now) == "Live updated 2 h ago · every 10 min")
        #expect(PopoverText.subtitle(lastLiveFetch: now - 3 * 86400, intervalMinutes: 5, now: now) == "Live updated 3 d ago · every 5 min")
        #expect(PopoverText.subtitle(lastLiveFetch: nil, intervalMinutes: 5, now: now) == "Not updated yet · every 5 min")
    }
}

/// Builds one row through a card, the public way rows are made.
fileprivate struct AccountRowProbe {
    let row: AccountRow
    init(_ account: AccountSnapshot) {
        let other = AccountSnapshot(key: AccountKey(tool: account.key.tool, id: "~probe-live"), label: "~", plan: nil, isLive: !account.isLive,
                                    isSaved: true, kept: false, flag: .ok, reading: nil, stale: false)
        let c = ToolCard.build(ToolSnapshot(tool: account.key.tool, live: .signedIn(testLogin(account.key.tool, "probe")), accounts: [account, other],
                                            rateLimitedUntil: nil), expanded: true, dismissedUnsavedKey: nil, now: now)
        row = account.isLive ? c.liveRow! : c.others.first { $0.id == account.key }!
    }
}
