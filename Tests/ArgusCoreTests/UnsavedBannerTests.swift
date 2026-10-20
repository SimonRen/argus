import Foundation
import Testing
import ArgusCore

@MainActor fileprivate func commands(_ rig: PollerRig, settleTime: Duration = .seconds(2)) -> AccountCommands {
    let switcher = Switcher(env: rig.box.env, vault: rig.vault, processes: ProcessListing { [] })
    return AccountCommands(state: rig.state, poller: rig.poller, vault: rig.vault, tools: Tool.allCases.map { rig.tools[$0]! }, switcher: switcher,
                           settleTime: settleTime)
}

@MainActor fileprivate func banner(_ rig: PollerRig, _ cmds: AccountCommands, _ tool: Tool) -> String? {
    ToolCard.build(rig.state.snapshot(.default(tool)), expanded: false, dismissedUnsavedKey: cmds.dismissedUnsaved[.default(tool)], now: rig.clock.now).unsavedBanner
}

/// A ChatGPT `auth.json` for `<tag>@example.com`.
fileprivate func codexAuth(_ tag: String) -> String {
    let id = testJWT(["email": "\(tag)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-\(tag)"]])
    return #"{"auth_mode":"chatgpt","tokens":{"id_token":"\#(id)","access_token":"test-access-\#(tag)","refresh_token":"test-refresh-\#(tag)"}}"#
}

/// Holds `tool`'s exclusive section, as a renewal in flight would, until the gate opens.
fileprivate func holdSection(_ vault: Vault, _ tool: Tool) async -> (gate: TestGate, task: Task<Void, any Error>) {
    let started = TestGate(), gate = TestGate()
    let task = Task { try await vault.exclusive(tool) { await started.release(); await gate.wait() } }
    await started.wait()
    return (gate, task)
}

@MainActor @Suite struct UnsavedBannerTests {
    // MARK: F01-AC-1.c9

    @Test func `REQ/F01-AC-1.c9 a complete live identity matching no saved account shows the unsaved banner`() async throws {
        let rig = try PollerRig(live: [.codex: [.signedIn(testLogin(.codex, "bob"))]])
        let cmds = commands(rig)
        await rig.poller.runBatch()
        #expect(banner(rig, cmds, .codex) == "Codex is signed in as bob@example.com, which isn't saved yet.")
        #expect(banner(rig, cmds, .claude) == nil)
    }

    @Test func `REQ/F01-AC-1.c9 a saved or incomplete live identity shows no banner`() async throws {
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))], .agy: [.signedIn(testLogin(.agy, "g", complete: false))]])
        try await rig.save(testLogin(.claude, "a"))
        let cmds = commands(rig)
        await rig.poller.runBatch()
        #expect(banner(rig, cmds, .claude) == nil)
        #expect(banner(rig, cmds, .agy) == nil)
    }

    // MARK: F06-AC-6.c10

    @Test func `REQ/F06-AC-6.c10 Save login saves the live login and clears the banner`() async throws {
        let rig = try PollerRig(live: [.agy: [.signedIn(testLogin(.agy, "g"))]])
        let cmds = commands(rig)
        await rig.poller.runBatch()
        #expect(banner(rig, cmds, .agy) != nil)
        #expect(await cmds.save(.default(.agy)) == .saved(email: "g@example.com"))
        #expect(cmds.notice == "Saved g@example.com.")
        #expect(banner(rig, cmds, .agy) == nil)
        #expect(rig.state.snapshot(.default(.agy)).accounts.first?.isSaved == true)
        #expect(await cmds.save(.default(.agy)) == .updated(email: "g@example.com"))
        #expect(cmds.notice == "Updated the saved login for g@example.com.")
    }

    @Test func `REQ/F06-AC-6.c10 Later hides the banner until the live identity changes`() async throws {
        let rig = try PollerRig(live: [.codex: [.signedIn(testLogin(.codex, "bob"))]])
        let cmds = commands(rig)
        await rig.poller.runBatch()
        cmds.later(.default(.codex))
        #expect(banner(rig, cmds, .codex) == nil)
        rig.clock.advance(300)
        await rig.poller.runBatch()
        #expect(banner(rig, cmds, .codex) == nil)
        rig.tools[.codex]!.script([.signedIn(testLogin(.codex, "carol"))])
        await rig.poller.refreshLive()
        #expect(banner(rig, cmds, .codex) == "Codex is signed in as carol@example.com, which isn't saved yet.")
    }

    @Test func `Save is refused with the reason for a wiped, unreadable or incomplete login`() async throws {
        for (state, reason) in [(LiveState.wiped, "signed out"), (.unknown("x"), "can't be read"),
                                (.signedIn(testLogin(.claude, "c", complete: false)), "incomplete identity")] {
            let rig = try PollerRig(live: [.claude: [state]])
            let cmds = commands(rig)
            #expect(await cmds.save(.default(.claude)) == .refused(reason))
            #expect(cmds.notice == reason)
            #expect(cmds.noticeIsProblem)
            #expect(await rig.vault.entries(.default(.claude)).isEmpty)
        }
    }

    @Test func `Save marks its context as saving while it waits for the tool's queued work`() async throws {
        let rig = try PollerRig(live: [.agy: [.signedIn(testLogin(.agy, "g"))]])
        let cmds = commands(rig)
        let agy = await holdSection(rig.vault, .agy)
        let saving = Task { await cmds.save(.default(.agy)) }
        while cmds.pending[.default(.agy)] == nil { await Task.yield() }
        #expect(cmds.pending[.default(.agy)] == .saving)
        #expect(await rig.vault.entries(.default(.agy)).isEmpty)
        await agy.gate.release()
        #expect(await saving.value == .saved(email: "g@example.com"))
        #expect(cmds.pending.isEmpty)
        try await agy.task.value
    }

    @Test func `a switch's notice shows without waiting for another tool's queued work`() async throws {
        let rig = try PollerRig(live: [.agy: [.signedIn(testLogin(.agy, "g", expiry: Date(timeIntervalSince1970: 4_100_000_000)))]])
        // agy's live bytes differ from its saved ones: rereading agy syncs them back, inside agy's exclusive section.
        try await rig.save(testLogin(.agy, "g"))
        try rig.box.write("codex/auth.json", codexAuth("b"))
        let target = try await rig.vault.save(await CodexTool(env: rig.box.env).readLive())
        try rig.box.write("codex/auth.json", codexAuth("a"))
        let agy = await holdSection(rig.vault, .agy), codex = await holdSection(rig.vault, .codex)
        let cmds = commands(rig)
        let key = AccountKey(tool: .codex, id: target.identity.fileID)
        let switching = Task { await cmds.switchTo(key, in: .default(.codex)) }
        while cmds.pending[.default(.codex)] == nil { await Task.yield() }
        #expect(cmds.pending[.default(.codex)] == .switching(key))
        #expect(cmds.notice == nil)
        await codex.gate.release()
        try await codex.task.value
        var waited = 0
        while cmds.notice == nil, waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(cmds.notice == "Codex now signs in as b@example.com.")
        #expect(cmds.pending == [.default(.codex): .switched(key, ok: true)])
        // Only the live refresh after the notice waits for agy's section.
        await agy.gate.release()
        #expect(await switching.value == .switched(notice: "Codex now signs in as b@example.com.", daemonRunning: false))
        try await agy.task.value
    }

    // A switch that went through is held as `.switched(_, ok: true)` in the notice test above.
    @Test func `a refused switch also holds its context for the settle time, then frees it`() async throws {
        let rig = try PollerRig()
        let cmds = commands(rig, settleTime: .milliseconds(200))
        let context = ToolContext.default(.codex), gone = AccountKey(tool: .codex, id: "gone")
        #expect(await cmds.switchTo(gone, in: context) == .refused("That saved account is gone."))
        #expect(cmds.pending[context] == .switched(gone, ok: false))
        var waited = 0
        while cmds.pending[context] != nil, waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(cmds.pending[context] == nil)
    }

    @Test func `a switch through the commands sets the notice and refreshes the live accounts`() async throws {
        let rig = try PollerRig()
        try rig.box.write("codex/auth.json", codexAuth("b"))
        let target = try await rig.vault.save(await CodexTool(env: rig.box.env).readLive())
        try rig.box.write("codex/auth.json", codexAuth("a"))
        let cmds = commands(rig)
        let outcome = await cmds.switchTo(AccountKey(tool: .codex, id: target.identity.fileID), in: .default(.codex))
        #expect(outcome == .switched(notice: "Codex now signs in as b@example.com.", daemonRunning: false))
        #expect(cmds.notice == "Codex now signs in as b@example.com.")
        #expect(rig.tools[.codex]!.reads >= 2)   // read again, then refreshed
        #expect(rig.state.saved(.default(.codex)).count == 2)
        cmds.dismissNotice()
        #expect(cmds.notice == nil)
        #expect(!cmds.noticeIsProblem)
        #expect(await cmds.switchTo(AccountKey(tool: .codex, id: "gone"), in: .default(.codex)) == .refused("That saved account is gone."))
        #expect(cmds.notice == "That saved account is gone.")
        #expect(cmds.noticeIsProblem)
    }

    @Test func `REQ/F03-AC-3.c14 a Codex switch with the app-server running restarts it at once and says how it went`() async throws {
        let lead = "Codex now signs in as b@example.com."
        for failure in [nil, "timed out"] as [String?] {
            let rig = try PollerRig()
            try rig.box.write("codex/auth.json", codexAuth("b"))
            let target = try await rig.vault.save(await CodexTool(env: rig.box.env).readLive())
            try rig.box.write("codex/auth.json", codexAuth("a"))
            let gate = TestGate()
            let switcher = Switcher(env: rig.box.env, vault: rig.vault, processes: ProcessListing { ["77 /opt/homebrew/bin/codex app-server --managed-daemon"] })
            let cmds = AccountCommands(state: rig.state, poller: rig.poller, vault: rig.vault, tools: Tool.allCases.map { rig.tools[$0]! },
                                       switcher: switcher, restartDaemon: { _ in await gate.wait(); return failure })
            let switching = Task { await cmds.switchTo(AccountKey(tool: .codex, id: target.identity.fileID), in: .default(.codex)) }
            while cmds.notice == nil { await Task.yield() }
            #expect(cmds.notice == lead + " Restarting the Codex app-server so open sessions move over; a running reply gets up to a minute to finish.")
            #expect(!cmds.offersRestart)
            await gate.release()
            #expect(await switching.value == .switched(notice: lead, daemonRunning: true))
            if let failure {
                #expect(cmds.notice == lead + " The Codex app-server didn't restart (\(failure)), so it still uses the previous account.")
                #expect(cmds.offersRestart && cmds.noticeIsProblem)
            } else {
                #expect(cmds.notice == lead + " Restarted the Codex app-server; open sessions reconnect on their own.")
                #expect(!cmds.offersRestart)
            }
        }
    }
}
