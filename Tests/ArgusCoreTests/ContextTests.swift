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

    @Test func `REQ/F09-AC-9.c4 one account live in two contexts is fetched once and shows live in both sections`() async throws {
        let a = testLogin(.codex, "a")
        let rig = try PollerRig(live: [.codex: [.signedIn(a)]])
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, .codex, live: .signedIn(a))
        await rig.poller.refreshLive()
        #expect(rig.count("a") == 1)
        #expect(rig.state.liveContexts(testKey(a)) == [.default(.codex), work])
        #expect(rig.state.snapshot(work).context == work)
        for context in [.default(.codex), work] {
            #expect(rig.state.snapshot(context).accounts.filter(\.isLive).map(\.key) == [testKey(a)])
        }
    }

    // MARK: F09-AC-9.c6

    @Test func `REQ/F09-AC-9.c6 each context lists its own saved accounts; removing one from a context leaves the others'`() async throws {
        let a = testLogin(.claude, "a"), b = testLogin(.claude, "b"), c = testLogin(.claude, "c")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]])
        for login in [a, c] { try await rig.save(login) }
        await rig.poller.reloadVault()
        let cmds = commands(rig)
        func card(_ context: ToolContext) -> ToolCard {
            ToolCard.build(rig.state.snapshot(context), expanded: true, dismissedUnsavedKey: nil, now: Date())
        }
        // One context: the tool's plain card.
        #expect(card(.default(.claude)).contextName == nil && card(.default(.claude)).rows.count == 2)
        // A new context's list starts empty: its live login shows unsaved until saved there.
        let work = await addWork(rig, cmds, live: .signedIn(b))
        #expect(card(work).rows.map(\.id) == [testKey(b)] && card(work).rows.first?.isSaved == false)
        #expect(await cmds.save(work) == .saved(email: "b@example.com"))
        // c signed in separately in Work too: its own grant in its own list.
        try await rig.vault.save(.signedIn(grant(.claude, "c", "work", expiry: start.addingTimeInterval(3600))), in: work)
        await rig.poller.reloadVault()
        let main = card(.default(.claude)), other = card(work)
        #expect(main.contextName == "Default" && main.liveRow?.id == testKey(a))
        #expect(other.contextName == "Work" && other.liveRow?.id == testKey(b))
        #expect(main.rows.map(\.id) == [testKey(a), testKey(c)])
        #expect(other.rows.map(\.id) == [testKey(b), testKey(c)] && other.rows.allSatisfy(\.isSaved))
        await cmds.remove(testKey(c), in: work)
        #expect(card(work).rows.map(\.id) == [testKey(b)])
        #expect(card(.default(.claude)).rows.map(\.id) == [testKey(a), testKey(c)])
    }

    @Test func `REQ/F09-AC-9.c4 an account saved in two contexts is fetched once, with the copy lasting longest, and both show its reading`() async throws {
        let rig = try PollerRig()
        try await rig.save(grant(.claude, "c", "home", expiry: start.addingTimeInterval(3600)))
        let work = await addWork(rig, commands(rig), live: .notSignedIn)
        try await rig.vault.save(.signedIn(grant(.claude, "c", "work", expiry: start.addingTimeInterval(7200))), in: work)
        await rig.poller.runBatch()
        #expect(rig.count("work") == 1 && rig.count("home") == 0)
        for context in [.default(.claude), work] {
            #expect(rig.state.snapshot(context).accounts.map { $0.reading != nil } == [true])
        }
    }

    @Test func `REQ/F09-AC-9.c5 Save refuses a login another context's list holds: a copied folder`() async throws {
        let x = testLogin(.codex, "x")
        let rig = try PollerRig(live: [.codex: [.signedIn(x)]])
        try await rig.save(x)
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, .codex, live: .signedIn(x))
        #expect(await cmds.save(work) == .refused("this exact login is already saved in another context, and one login in two contexts signs one of them out"))
        #expect(await rig.vault.entries(work).isEmpty)
    }

    @Test func `REQ/F09-AC-9.c6 a section saves its own context's live login and names it in the unsaved banner`() async throws {
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))]])
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, live: .signedIn(testLogin(.claude, "w")))
        func banner(_ context: ToolContext) -> String? {
            ToolCard.build(rig.state.snapshot(context), expanded: false, dismissedUnsavedKey: cmds.dismissedUnsaved[context], now: Date()).unsavedBanner
        }
        #expect(banner(work) == "Claude Code (Work) is signed in as w@example.com, which isn't saved yet.")
        #expect(banner(.default(.claude)) == "Claude Code (Default) is signed in as a@example.com, which isn't saved yet.")
        cmds.later(work)
        #expect(banner(work) == nil && banner(.default(.claude)) != nil)
        #expect(await cmds.save(work) == .saved(email: "w@example.com"))
        #expect(rig.state.snapshot(work).accounts.first { $0.isLive }?.isSaved == true)
    }

    @Test func `REQ/F09-AC-9.c6 the menubar shows each shown context, an added one by name, each with its own Show choices`() async throws {
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))]])
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, live: .signedIn(testLogin(.claude, "w")))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let prefs = MenuBarPreferences(defaults: defaults)
        func summary() -> MenuBarSummary {
            MenuBarSummary.build(Tool.allCases.flatMap(rig.state.contexts).map(rig.state.snapshot), isShown: prefs.isShown)
        }
        #expect(summary().segments.map(\.context) == [nil, "Work"])
        #expect(summary().accessibilityLabel == "Claude Code 7 d —; Claude Code (Work) 7 d —")
        prefs.setShown(work, false)
        prefs.setInPopover(.default(.claude), false)
        #expect(summary().segments.map(\.context) == [nil])
        let relaunched = MenuBarPreferences(defaults: defaults)
        #expect(!relaunched.isShown(work) && relaunched.isShown(.default(.claude)))
        #expect(!relaunched.isInPopover(.default(.claude)) && relaunched.isInPopover(work))
        // The default context keeps the key it had before contexts.
        #expect(defaults.object(forKey: "showInPopover.claude") as? Bool == false)
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

    @Test func `REQ/F09-AC-9.c5 contexts persist; removing one forgets its live login`() async throws {
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
        #expect(state.liveState(work) == .notSignedIn)

        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.contexts(.codex) == [.default(.codex), work])
        #expect(relaunched.contexts(.claude) == [.default(.claude)] && relaunched.contexts(.agy) == [.default(.agy)])

        #expect(await cmds.removeContext(work) == nil)
        #expect(state.liveState(work) == nil)
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

    @Test func `REQ/F09-AC-9.c4 an account live in two contexts is fetched with the login lasting longest; each context syncs back into its own list`() async throws {
        let old = grant(.codex, "x", "old", expiry: start.addingTimeInterval(-60)), new = grant(.codex, "x", "new", expiry: start.addingTimeInterval(3600))
        let rig = try PollerRig(live: [.codex: [.signedIn(old)]])
        try await rig.save(old)
        let cmds = commands(rig)
        let work = ToolContext(tool: .codex, path: rig.box.root.appending(path: "codex-work").path, name: "Work"), reader = FakeTool(.codex, [.signedIn(new)])
        rig.tools[.codex]!.add(work, reader)
        #expect(await cmds.addContext(.codex, path: work.path!, name: "Work") == nil)
        #expect(await cmds.save(work) == .saved(email: "x@example.com"))
        await rig.poller.runBatch()
        #expect(rig.count("new") == 1 && rig.count("old") == 0)
        #expect(rig.state.status[testKey(old)]?.error == nil)
        // Work renews its login: it lands in Work's list, never in the default's.
        let newer = grant(.codex, "x", "newer", expiry: start.addingTimeInterval(7200))
        reader.script([.signedIn(newer)])
        await rig.poller.rereadLive()
        guard case .valid(let home)? = await rig.vault.entry(.default(.codex), id: testKey(old).id),
              case .valid(let own)? = await rig.vault.entry(work, id: testKey(old).id) else { Issue.record("entry gone"); return }
        #expect(home.payloadBytes == old.bytes && own.payloadBytes == newer.bytes)
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

    @Test func `REQ/F09-AC-9.c5 a removed context's saved logins stay on disk, unread and unrenewed, and come back when it is added again`() async throws {
        let rig = try PollerRig(renewing: true)
        let cmds = commands(rig)
        let work = await addWork(rig, cmds, .codex, live: .signedIn(testLogin(.codex, "x")))
        #expect(await cmds.save(work) == .saved(email: "x@example.com"))
        // A saved account due for renewal.
        try await rig.vault.save(.signedIn(testLogin(.codex, "w", expiry: start.addingTimeInterval(60))), in: work)
        #expect(await cmds.removeContext(work) == nil)
        #expect(rig.state.saved(work).isEmpty && !rig.state.contexts(.codex).contains(work))
        await rig.poller.runBatch()
        #expect(rig.tokenRequests.isEmpty && rig.count("w") == 0 && rig.count("x") == 0)
        #expect(await rig.vault.entries(work).count == 2)
        #expect(await cmds.addContext(.codex, path: work.path!, name: "Work") == nil)
        #expect(rig.state.saved(work).count == 2)
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
