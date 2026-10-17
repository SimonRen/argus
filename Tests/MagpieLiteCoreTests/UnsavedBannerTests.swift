import Foundation
import Testing
import MagpieLiteCore

@MainActor fileprivate func commands(_ rig: PollerRig) -> AccountCommands {
    let switcher = Switcher(env: rig.box.env, vault: rig.vault, processes: ProcessListing { [] })
    return AccountCommands(state: rig.state, poller: rig.poller, vault: rig.vault, tools: Tool.allCases.map { rig.tools[$0]! }, switcher: switcher)
}

@MainActor fileprivate func banner(_ rig: PollerRig, _ cmds: AccountCommands, _ tool: Tool) -> String? {
    ToolCard.build(rig.state.snapshot(tool), expanded: false, dismissedUnsavedKey: cmds.dismissedUnsaved[tool], now: rig.clock.now).unsavedBanner
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
        #expect(await cmds.save(.agy) == .saved(email: "g@example.com"))
        #expect(cmds.notice == "Saved g@example.com.")
        #expect(banner(rig, cmds, .agy) == nil)
        #expect(rig.state.snapshot(.agy).accounts.first?.isSaved == true)
        #expect(await cmds.save(.agy) == .updated(email: "g@example.com"))
        #expect(cmds.notice == "Updated the saved login for g@example.com.")
    }

    @Test func `REQ/F06-AC-6.c10 Later hides the banner until the live identity changes`() async throws {
        let rig = try PollerRig(live: [.codex: [.signedIn(testLogin(.codex, "bob"))]])
        let cmds = commands(rig)
        await rig.poller.runBatch()
        cmds.later(.codex)
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
            #expect(await cmds.save(.claude) == .refused(reason))
            #expect(cmds.notice == reason)
            #expect(await rig.vault.entries(.claude).isEmpty)
        }
    }

    @Test func `a switch through the commands sets the notice and refreshes the live accounts`() async throws {
        func auth(_ tag: String) -> String {
            let id = testJWT(["email": "\(tag)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-\(tag)"]])
            return #"{"auth_mode":"chatgpt","tokens":{"id_token":"\#(id)","access_token":"test-access-\#(tag)","refresh_token":"test-refresh-\#(tag)"}}"#
        }
        let rig = try PollerRig()
        try rig.box.write("codex/auth.json", auth("b"))
        let target = try await rig.vault.save(await CodexTool(env: rig.box.env).readLive())
        try rig.box.write("codex/auth.json", auth("a"))
        let cmds = commands(rig)
        let outcome = await cmds.switchTo(AccountKey(tool: .codex, id: target.identity.fileID))
        #expect(outcome == .switched(notice: "Codex now signs in as b@example.com.", daemonRunning: false))
        #expect(cmds.notice == "Codex now signs in as b@example.com.")
        #expect(rig.state.lastLiveFetch != nil)
        #expect(rig.state.entries[.codex]?.count == 2)
        cmds.dismissNotice()
        #expect(cmds.notice == nil)
        #expect(await cmds.switchTo(AccountKey(tool: .codex, id: "gone")) == .refused("That saved account is gone."))
        #expect(cmds.notice == "That saved account is gone.")
    }

    @Test func `REQ/F03-AC-3.c14 a Codex switch with the app-server running restarts it at once and says how it went`() async throws {
        func auth(_ tag: String) -> String {
            let id = testJWT(["email": "\(tag)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-\(tag)"]])
            return #"{"auth_mode":"chatgpt","tokens":{"id_token":"\#(id)","access_token":"test-access-\#(tag)","refresh_token":"test-refresh-\#(tag)"}}"#
        }
        let lead = "Codex now signs in as b@example.com."
        for failure in [nil, "timed out"] as [String?] {
            let rig = try PollerRig()
            try rig.box.write("codex/auth.json", auth("b"))
            let target = try await rig.vault.save(await CodexTool(env: rig.box.env).readLive())
            try rig.box.write("codex/auth.json", auth("a"))
            let gate = TestGate()
            let switcher = Switcher(env: rig.box.env, vault: rig.vault, processes: ProcessListing { ["77 /opt/homebrew/bin/codex app-server --managed-daemon"] })
            let cmds = AccountCommands(state: rig.state, poller: rig.poller, vault: rig.vault, tools: Tool.allCases.map { rig.tools[$0]! },
                                       switcher: switcher, restartDaemon: { await gate.wait(); return failure })
            let switching = Task { await cmds.switchTo(AccountKey(tool: .codex, id: target.identity.fileID)) }
            while cmds.notice == nil { await Task.yield() }
            #expect(cmds.notice == lead + " Restarting the Codex app-server so open sessions move over; a running reply gets up to a minute to finish.")
            #expect(!cmds.offersRestart)
            await gate.release()
            #expect(await switching.value == .switched(notice: lead, daemonRunning: true))
            if let failure {
                #expect(cmds.notice == lead + " The Codex app-server didn't restart (\(failure)), so it still uses the previous account.")
                #expect(cmds.offersRestart)
            } else {
                #expect(cmds.notice == lead + " Restarted the Codex app-server; open sessions reconnect on their own.")
                #expect(!cmds.offersRestart)
            }
        }
    }
}
