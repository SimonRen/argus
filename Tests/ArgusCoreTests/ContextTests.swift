import Foundation
import Testing
import ArgusCore

@MainActor fileprivate func commands(_ rig: PollerRig) -> AccountCommands {
    let switcher = Switcher(env: rig.box.env, vault: rig.vault, processes: ProcessListing { [] })
    return AccountCommands(state: rig.state, poller: rig.poller, vault: rig.vault, tools: Tool.allCases.map { rig.tools[$0]! }, switcher: switcher)
}

/// A Claude context named Work in the sandbox whose fake reader returns `live`.
@MainActor fileprivate func addWork(_ rig: PollerRig, _ cmds: AccountCommands, _ tool: Tool = .claude, live: LiveState) async -> ToolContext {
    let work = ToolContext(tool: tool, path: rig.box.root.appending(path: "\(tool.rawValue)-work").path, name: "Work")
    rig.tools[tool]!.add(work, FakeTool(tool, [live]))
    #expect(await cmds.addContext(tool, path: work.path!, name: "Work") == nil)
    return work
}

/// `account`'s identity on another grant: what a separate sign-in in a second context gives.
fileprivate func grant(_ tool: Tool, _ account: String, _ tag: String, expiry: Date) -> LiveLogin {
    let base = testLogin(tool, account), c = testCredential(tool, tag, expiry: expiry)
    return LiveLogin(identity: base.identity, plan: base.plan, label: base.label, bytes: c.bytes, tokens: c.tokens, clientID: nil,
                     claudeAccount: base.claudeAccount, accountID: base.accountID)
}

fileprivate let start = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor @Suite struct ContextTests {
    // MARK: F09-AC-9.c4

    @Test func `REQ/F09-AC-9.c4 a batch reads every context, fetches each live account once, and never renews an account live in another context`() async throws {
        let soon = Date(timeIntervalSince1970: 1_790_000_000 + 120)
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b", expiry: soon)
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]], renewing: true)
        try await rig.save(a)
        try await rig.save(b)
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, live: .signedIn(b))
        await rig.poller.runBatch()
        // b is due for renewal, but it is Work's live login: Claude Code renews it, the app only reads it.
        #expect(rig.tokenRequests.isEmpty)
        #expect(rig.count("a") == 1 && rig.count("b") == 1)
        #expect(rig.state.liveContexts(testKey(b)) == [work])
        #expect(rig.state.status[testKey(b)]?.reading != nil)
    }

    @Test func `REQ/F09-AC-9.c4 one account live in two contexts is fetched once, the selected context shows its own live login`() async throws {
        let a = testLogin(.codex, "a")
        let rig = try PollerRig(live: [.codex: [.signedIn(a)]])
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, .codex, live: .signedIn(a))
        await rig.poller.refreshLive()
        #expect(rig.count("a") == 1)
        #expect(rig.state.liveContexts(testKey(a)) == [.default(.codex), work])
        cmds.selectContext(work)
        #expect(rig.state.snapshot(.codex).context == work)
        #expect(rig.state.snapshot(.codex).accounts.first { $0.key == testKey(a) }?.liveElsewhere == ["Default"])
    }

    // MARK: F09-AC-9.c6

    @Test func `REQ/F09-AC-9.c6 a row live in another context reads live in it, its Switch is disabled, and it is never suggested`() async throws {
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]])
        try await rig.save(a)
        try await rig.save(b)
        await rig.poller.reloadVault()
        let cmds = commands(rig)
        #expect(ToolCard.build(rig.state.snapshot(.claude), expanded: true, dismissedUnsavedKey: nil, now: Date()).contexts.isEmpty)
        let work = await addWork(rig, cmds, live: .signedIn(b))
        let card = ToolCard.build(rig.state.snapshot(.claude), expanded: true, dismissedUnsavedKey: nil, now: Date())
        #expect(card.contexts == [.default(.claude), work] && card.context == .default(.claude))
        let row = try #require(card.rows.first { $0.id == testKey(b) })
        #expect(!row.isLive && row.liveElsewhere == ["Work"])
        #expect(row.switchDisabledReason == "Live in Work")
        #expect(row.subtitle == "Pro · live in Work")
        #expect(card.suggestion == nil)
        // In Work the roles swap.
        cmds.selectContext(work)
        let other = ToolCard.build(rig.state.snapshot(.claude), expanded: true, dismissedUnsavedKey: nil, now: Date())
        #expect(other.liveRow?.id == testKey(b) && other.rows.first { $0.id == testKey(a) }?.switchDisabledReason == "Live in Default")
    }

    @Test func `REQ/F09-AC-9.c6 Save takes the selected context's live login`() async throws {
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))]])
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, live: .signedIn(testLogin(.claude, "w")))
        cmds.selectContext(work)
        #expect(await cmds.save(.claude) == .saved(email: "w@example.com"))
    }

    // MARK: F09-AC-9.c5

    @Test func `REQ/F09-AC-9.c5 a context needs a full path not already a context, and a name of its own`() async throws {
        let rig = try PollerRig()
        let cmds = commands(rig)
        let root = rig.box.root.path
        #expect(await cmds.addContext(.claude, path: "claude-work", name: "") == "Use the full path, as the shell exports it.")
        #expect(await cmds.addContext(.agy, path: root + "/agy", name: "") == "Antigravity CLI has no setting for another folder.")
        #expect(await cmds.addContext(.claude, path: " \(root)/.claude-work ", name: "") == nil)
        #expect(rig.state.contexts(.claude).last == ToolContext(tool: .claude, path: root + "/.claude-work", name: "claude-work"))
        #expect(await cmds.addContext(.claude, path: root + "/.claude-work/", name: "") == "That folder is already a Claude Code context.")
        #expect(await cmds.addContext(.claude, path: root + "/other", name: "CLAUDE-work") == "Another Claude Code context is named CLAUDE-work.")
        // A shell expands ~/ in an assignment, so the context holds the full path.
        #expect(await cmds.addContext(.claude, path: "~/.claude-home", name: "Home") == nil)
        #expect(rig.state.contexts(.claude).last?.path == rig.box.home.path + "/.claude-home")
        // Codex resolves its home: the default home under another spelling is no new context.
        #expect(await cmds.addContext(.codex, path: rig.box.codexHome.path + "/", name: "") == "That folder is already a Codex context.")
    }

    @Test func `REQ/F09-AC-9.c5 contexts and the selection persist; removing the selected one hands over to the default`() async throws {
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let state = AppState(defaults: defaults)
        let fetcher = AllowanceFetcher(http: HTTPClient(session: TestHTTPStub(okReply).session), version: "0", now: { Date() })
        let tools: [any ToolAdapter] = Tool.allCases.map { FakeTool($0, [.notSignedIn]) }
        let poller = Poller(state: state, tools: tools, vault: vault, fetcher: fetcher, sleeper: RecordingSleeper(), now: { Date() })
        let cmds = AccountCommands(state: state, poller: poller, vault: vault, tools: tools,
                                   switcher: Switcher(env: box.env, vault: vault, processes: ProcessListing { [] }))
        #expect(await cmds.addContext(.codex, path: box.root.path + "/codex-work", name: "Work") == nil)
        let work = state.contexts(.codex)[1]
        cmds.selectContext(work)
        #expect(state.live[.codex]?[work.id] == .notSignedIn)

        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.contexts(.codex) == [.default(.codex), work])
        #expect(relaunched.selectedContext(.codex) == work)
        #expect(relaunched.contexts(.claude) == [.default(.claude)] && relaunched.contexts(.agy) == [.default(.agy)])

        #expect(await cmds.removeContext(work) == nil)
        #expect(state.selectedContext(.codex) == .default(.codex) && state.live[.codex]?[work.id] == nil)
        #expect(AppState(defaults: defaults).contexts(.codex) == [.default(.codex)])
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F09-AC-9.c5 a context row says whether its exact path holds a login`() {
        let work = ToolContext(tool: .claude, path: "/tmp/w", name: "Work")
        #expect(ManagerText.contextStatus(nil, context: work) == "Not read yet")
        #expect(ManagerText.contextStatus(.signedIn(testLogin(.claude, "a")), context: work) == "Signed in as a@example.com")
        #expect(ManagerText.contextStatus(.notSignedIn, context: work) == "Not signed in · CLAUDE_CONFIG_DIR must be exactly this path")
        #expect(ManagerText.contextStatus(.notSignedIn, context: .default(.codex)) == "Not signed in")
        #expect(work.assignment == "CLAUDE_CONFIG_DIR=/tmp/w" && ToolContext.default(.claude).assignment == nil)
    }

    // MARK: Hardening

    @Test func `REQ/F09-AC-9.c4 an account live in two contexts is fetched with the login lasting longest and synced back from it`() async throws {
        let old = grant(.codex, "x", "old", expiry: start.addingTimeInterval(-60)), new = grant(.codex, "x", "new", expiry: start.addingTimeInterval(3600))
        let rig = try PollerRig(live: [.codex: [.signedIn(old)]])
        try await rig.save(old)
        _ = await addWork(rig, commands(rig), .codex, live: .signedIn(new))
        await rig.poller.runBatch()
        #expect(rig.count("new") == 1 && rig.count("old") == 0)
        #expect(rig.state.status[testKey(old)]?.error == nil)
        guard case .valid(let entry)? = await rig.vault.entry(.codex, id: testKey(old).id) else { Issue.record("entry gone"); return }
        #expect(entry.payloadBytes == new.bytes)
    }

    @Test func `REQ/F09-AC-9.c4 an expired live token in a context names it`() async throws {
        let rig = try PollerRig()
        _ = await addWork(rig, commands(rig), live: .signedIn(testLogin(.claude, "e", expiry: start.addingTimeInterval(-60))))
        await rig.poller.runBatch()
        #expect(rig.state.status[testKey(testLogin(.claude, "e"))]?.error == "its sign-in has expired; use Claude Code in Work once to renew it")
    }

    @Test func `REQ/F09-AC-9.c4 a Codex context signed in with an API key doesn't hold up renewal, one in keyring storage does`() async throws {
        let soon = start.addingTimeInterval(120)
        for (other, renews) in [(LiveState.unsupported("an API-key sign-in"), true), (.unsupported("Codex keeps this login in the Keychain"), false)] {
            let rig = try PollerRig(renewing: true)
            try await rig.save(testLogin(.codex, "s", expiry: soon))
            _ = await addWork(rig, commands(rig), .codex, live: other)
            await rig.poller.runBatch()
            #expect(rig.tokenRequests.isEmpty != renews)
        }
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        try box.write("codex/auth.json", #"{"OPENAI_API_KEY":"sk-test","auth_mode":"apikey","tokens":null}"#)
        #expect(await CodexTool(env: box.env).readLive() == .unsupported("an API-key sign-in"))
    }

    @Test func `REQ/F09-AC-9.c5 a context running on the saved login can't be removed unless another context has that account live`() async throws {
        let x = testLogin(.codex, "x")
        let rig = try PollerRig()
        try await rig.save(x)
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, .codex, live: .signedIn(x))
        #expect(await cmds.removeContext(work) == "Work runs on the login saved for x@example.com. Once Argus stops reading Work, renewing that saved login "
            + "would sign it out. Sign out of Codex there, or remove the saved login, first.")
        #expect(rig.state.contexts(.codex).contains(work))
        // The default context also runs on it: still watched, so the context may go.
        rig.tools[.codex]!.script([.signedIn(x)])
        await rig.poller.rereadLive()
        #expect(await cmds.removeContext(work) == nil)

        // A separate sign-in there (another grant) isn't the saved login.
        let other = try PollerRig()
        try await other.save(x)
        let otherCmds = commands(other)
        let away = await addWork(other, otherCmds, .codex, live: .signedIn(grant(.codex, "x", "own", expiry: start.addingTimeInterval(3600))))
        // Codex syncs back at once, so the saved login is now Work's own grant again: put the first one back.
        try await other.save(x)
        #expect(await otherCmds.removeContext(away) == nil)
    }

    @Test func `REQ/F09-AC-9.c5 two contexts on one login (a copied folder) are flagged on both rows`() async throws {
        let x = testLogin(.codex, "x")
        let rig = try PollerRig(live: [.codex: [.signedIn(x)]])
        let work = await addWork(rig, commands(rig), .codex, live: .signedIn(x))
        #expect(rig.state.sharesLogin(work) == .default(.codex) && rig.state.sharesLogin(.default(.codex)) == work)
        #expect(ManagerText.contextStatus(.signedIn(x), context: work, sharedWith: .default(.codex))
            == "Signed in as x@example.com — the same login as Default: whichever renews first signs the other out. Sign in again in one of them.")
        let separate = await addWork(rig, commands(rig), .claude, live: .signedIn(testLogin(.claude, "c")))
        #expect(rig.state.sharesLogin(separate) == nil)
        #expect(ManagerText.contextStatus(.signedIn(testLogin(.claude, "i", complete: false)), context: separate)
            == "Signed in, but its account can't be read — saved Claude Code accounts aren't renewed meanwhile")
        #expect(ManagerText.contextStatus(.unsupported("an API-key sign-in"), context: work) == "Signed in with an API key, which Argus doesn't manage")
    }

    @Test func `REQ/F09-AC-9.c5 a link to a context's folder is that folder`() async throws {
        let rig = try PollerRig()
        let cmds = commands(rig)
        let real = rig.box.root.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: rig.box.root.appending(path: "link"), withDestinationURL: real)
        #expect(await cmds.addContext(.claude, path: real.path, name: "") == nil)
        #expect(await cmds.addContext(.claude, path: rig.box.root.appending(path: "link").path, name: "") == "That folder is already a Claude Code context.")
    }
}
