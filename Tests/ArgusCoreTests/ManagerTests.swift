import Foundation
import Testing
import ArgusCore

@MainActor fileprivate func commands(_ rig: PollerRig) -> AccountCommands {
    let switcher = Switcher(env: rig.box.env, vault: rig.vault, processes: ProcessListing { [] })
    return AccountCommands(state: rig.state, poller: rig.poller, vault: rig.vault, tools: Tool.allCases.map { rig.tools[$0]! }, switcher: switcher)
}

@MainActor fileprivate func file(_ rig: PollerRig, _ key: AccountKey) -> URL {
    rig.box.supportRoot.appending(path: "vault/\(key.tool.rawValue)/\(key.id).json")
}

@MainActor @Suite struct ManagerTests {
    // MARK: F07-AC-7.c2

    @Test func `REQ/F07-AC-7.c2 Remove deletes the file and prev, leaves the lists and the poll set, and offers Undo`() async throws {
        let rig = try PollerRig(live: [.codex: [.signedIn(testLogin(.codex, "a"))]])
        try rig.box.write("codex/auth.json", "live-bytes")
        let key = try await rig.save(testLogin(.codex, "b"))
        try await rig.save(testLogin(.codex, "b"))
        let cmds = commands(rig)
        await rig.poller.runBatch()
        #expect(rig.count("b") == 1)
        await cmds.remove(key)
        #expect(!FileManager.default.fileExists(atPath: file(rig, key).path))
        #expect(!FileManager.default.fileExists(atPath: file(rig, key).path + ".prev"))
        #expect(!rig.state.snapshot(.codex).accounts.contains { $0.key == key })
        #expect(cmds.undoBanner == "Removed b@example.com. Its saved login file was deleted.")
        #expect(try Data(contentsOf: rig.box.codexHome.appending(path: "auth.json")) == Data("live-bytes".utf8))
        rig.clock.advance(300)
        await rig.poller.runBatch()
        #expect(rig.count("b") == 1)
    }

    @Test func `REQ/F07-AC-7.c2 Remove waits for an earlier queued vault operation and captures its result`() async throws {
        let rig = try PollerRig()
        let key = try await rig.save(testLogin(.claude, "b"))
        let cmds = commands(rig)
        await rig.poller.reloadVault()
        let gate = TestGate()
        let vault = rig.vault
        let rotated = testCredential(.claude, "b2").bytes
        let renewal = Task { try await vault.exclusive(.claude) { await gate.wait(); try await vault.replacePayload(.claude, id: key.id, bytes: rotated, origin: .renewal) } }
        try await Task.sleep(for: .milliseconds(30))
        let removal = Task { await cmds.remove(key) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(FileManager.default.fileExists(atPath: file(rig, key).path))
        await gate.release()
        _ = try await renewal.value
        await removal.value
        await cmds.undo()
        guard case .valid(let restored)? = await rig.vault.entry(.claude, id: key.id) else { Issue.record("not restored"); return }
        #expect(restored.payloadBytes == rotated)
    }

    @Test func `REQ/F07-AC-7.c2 removing the live account's saved login shows it as unsaved`() async throws {
        let live = testLogin(.agy, "g")
        let rig = try PollerRig(live: [.agy: [.signedIn(live)]])
        let key = try await rig.save(live)
        let cmds = commands(rig)
        await rig.poller.runBatch()
        await cmds.remove(key)
        let account = try #require(rig.state.snapshot(.agy).accounts.first)
        #expect(account.isLive && !account.isSaved)
    }

    @Test func `REQ/F06-AC-6.c11 a refresh that sends nothing shows the hint; one that sends shows none`() async throws {
        let a = testLogin(.claude, "a")
        let rig = try PollerRig(live: [.claude: [.signedIn(a)]])
        let cmds = commands(rig)
        await cmds.refreshLive()
        #expect(cmds.hint == nil)
        rig.clock.advance(12)
        await cmds.refresh(testKey(a))
        #expect(cmds.hint == "Refreshed moments ago. Try again in 3 min.")
        #expect(rig.tags == ["a"])
    }

    // MARK: F07-AC-7.c3

    @Test func `REQ/F07-AC-7.c3 picking an interval persists it and the loop's next sleep uses it`() async throws {
        let rig = try PollerRig()
        let cmds = commands(rig)
        rig.poller.start()
        #expect(await eventually { rig.sleeper.durations.count == 1 })
        cmds.setInterval(10)
        #expect(await eventually { rig.sleeper.durations.count == 2 })
        #expect(rig.sleeper.durations == [.seconds(300), .seconds(600)])
        #expect(rig.state.intervalMinutes == 10)
        cmds.setInterval(7)
        #expect(rig.state.intervalMinutes == 10)
        rig.poller.stop()
    }

    @Test func `REQ/F07-AC-7.c3 the chosen interval survives a restart`() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = try TestSandbox(security: ScriptedSecurity([.timedOut]))
        let vault = try Vault(supportRoot: box.supportRoot)
        let state = AppState(defaults: defaults)
        let poller = Poller(state: state, tools: [], vault: vault, fetcher: AllowanceFetcher(http: HTTPClient(session: TestHTTPStub(okReply).session), version: "0", now: { Date() }),
                            sleeper: RecordingSleeper(), now: { Date() })
        let cmds = AccountCommands(state: state, poller: poller, vault: vault, tools: [], switcher: Switcher(env: box.env, vault: vault, processes: ProcessListing { [] }))
        cmds.setInterval(3)
        #expect(AppState(defaults: UserDefaults(suiteName: suite)!).intervalMinutes == 3)
    }

    // MARK: F07-AC-7.c5

    @Test func `REQ/F07-AC-7.c5 Undo writes the removed bytes back and the account returns to the lists and the poll set`() async throws {
        let rig = try PollerRig()
        let key = try await rig.save(testLogin(.codex, "b"))
        let bytes = try Data(contentsOf: file(rig, key))
        let cmds = commands(rig)
        await cmds.remove(key)
        await cmds.undo()
        #expect(try Data(contentsOf: file(rig, key)) == bytes)
        #expect(cmds.undoBanner == nil)
        #expect(rig.state.snapshot(.codex).accounts.contains { $0.key == key })
        await rig.poller.runBatch()
        #expect(rig.count("b") == 1)
    }

    @Test func `REQ/F07-AC-7.c5 Undo keeps a newer entry with the same id and closes the banner`() async throws {
        let rig = try PollerRig()
        let key = try await rig.save(testLogin(.codex, "b"))
        let cmds = commands(rig)
        await cmds.remove(key)
        try await rig.save(testLogin(.codex, "b", expiry: Date(timeIntervalSince1970: 4_100_000_000)))
        let newer = try Data(contentsOf: file(rig, key))
        await cmds.undo()
        #expect(try Data(contentsOf: file(rig, key)) == newer)
        #expect(cmds.undoBanner == nil)
    }

    // MARK: F07-AC-7.c6

    @Test func `REQ/F07-AC-7.c6 closing the banner or removing again drops the held bytes`() async throws {
        let rig = try PollerRig()
        let b = try await rig.save(testLogin(.codex, "b"))
        let c = try await rig.save(testLogin(.codex, "c"))
        let cmds = commands(rig)
        await cmds.remove(b)
        cmds.closeUndo()
        #expect(cmds.undoBanner == nil)
        await cmds.undo()
        #expect(!FileManager.default.fileExists(atPath: file(rig, b).path))
        try await rig.save(testLogin(.codex, "b"))
        await rig.poller.reloadVault()
        await cmds.remove(b)
        await cmds.remove(c)
        #expect(cmds.undoBanner == "Removed c@example.com. Its saved login file was deleted.")
        await cmds.undo()
        #expect(FileManager.default.fileExists(atPath: file(rig, c).path))
        #expect(!FileManager.default.fileExists(atPath: file(rig, b).path))
    }

    // MARK: F07-AC-7.c7

    @Test func `REQ/F07-AC-7.c7 Show in menubar changes the status item and the sidebar glyph at once`() async throws {
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))]])
        await rig.poller.runBatch()
        let prefs = MenuBarPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let snapshot = rig.state.snapshot(.claude)
        #expect(MenuBarSummary.build([snapshot], isShown: prefs.isShown).segments.count == 1)
        #expect(ManagerSidebarRow.build(snapshot, isShown: prefs.isShown(.claude)).showsMenubarGlyph)
        prefs.setShown(.claude, false)
        #expect(MenuBarSummary.build([snapshot], isShown: prefs.isShown).showsGlyphOnly)
        let row = ManagerSidebarRow.build(snapshot, isShown: prefs.isShown(.claude))
        #expect(!row.showsMenubarGlyph)
        #expect(row.liveEmail == "a@example.com" && row.fiveHour.text == "10%" && row.sevenDay.text == "20%")
    }

    @Test func `a sidebar row without a live login shows dashes`() {
        let snapshot = ToolSnapshot(tool: .codex, live: .notSignedIn, accounts: [], rateLimitedUntil: nil)
        let row = ManagerSidebarRow.build(snapshot, isShown: true)
        #expect(row.liveEmail == nil && row.fiveHour.text == "—" && row.sevenDay.text == "—")
    }

    // MARK: F07-AC-7.c8

    @Test func `REQ/F07-AC-7.c8 the save banner reads Saved for a new entry and Updated for an existing one`() async throws {
        #expect(ManagerText.saveBanner(.saved(email: "a@example.com")) == "Saved a@example.com.")
        #expect(ManagerText.saveBanner(.updated(email: "a@example.com")) == "Updated the saved login for a@example.com.")
        #expect(ManagerText.saveBanner(.refused("signed out")) == "signed out")
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))]])
        let cmds = commands(rig)
        #expect(ManagerText.saveBanner(await cmds.save(.claude)) == "Saved a@example.com.")
        #expect(ManagerText.saveBanner(await cmds.save(.claude)) == "Updated the saved login for a@example.com.")
    }

    // MARK: F07-AC-7.c9

    @Test func `REQ/F07-AC-7.c9 a tool without saved accounts shows the empty state`() {
        #expect(ManagerText.emptyTitle == "No saved accounts")
        #expect(ManagerText.emptyHint(.codex) == "Sign in with Codex as usual, then choose Save current login to keep it here.")
        #expect(ManagerText.emptyHint(.agy) == "Sign in with Antigravity CLI as usual, then choose Save current login to keep it here.")
    }

    @Test func `the detail header names the live login, whether it is saved, and the saved count`() async throws {
        let rig = try PollerRig(live: [.claude: [.signedIn(testLogin(.claude, "a"))], .codex: [.signedIn(testLogin(.codex, "x"))]])
        try await rig.save(testLogin(.claude, "a"))
        try await rig.save(testLogin(.claude, "b"))
        await rig.poller.runBatch()
        #expect(ManagerText.header(rig.state.snapshot(.claude)) == "Signed in as a@example.com")
        #expect(ManagerText.header(rig.state.snapshot(.codex)) == "Signed in as x@example.com — not saved")
        #expect(ManagerText.header(rig.state.snapshot(.agy)) == "Not signed in")
    }
}
