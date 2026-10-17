import Foundation
import Testing
import ArgusCore

/// The same identity as `testLogin(tool, tag)` with different live bytes (as after the tool refreshed its own tokens).
fileprivate func refreshed(_ tool: Tool, _ tag: String, _ marker: String) -> LiveLogin {
    let base = testLogin(tool, tag)
    var text = String(decoding: base.bytes, as: UTF8.self)
    text.insert(contentsOf: #""marker":"\#(marker)","#, at: text.index(after: text.startIndex))
    return LiveLogin(identity: base.identity, plan: base.plan, label: base.label, bytes: Data(text.utf8), tokens: base.tokens,
                     clientID: base.clientID, claudeAccount: base.claudeAccount, accountID: base.accountID)
}

fileprivate func entry(_ rig: PollerRig, _ key: AccountKey) async -> VaultEnvelope? {
    if case .valid(let e)? = await rig.vault.entry(key.tool, id: key.id) { return e }
    return nil
}

@MainActor @Suite struct SyncBackTests {
    // MARK: F04-AC-4.c24

    @Test func `REQ/F04-AC-4.c24 a batch copies a saved live account's changed live bytes into its entry, keeping kept`() async throws {
        let live = refreshed(.codex, "e", "r1")
        let rig = try PollerRig(live: [.codex: [.signedIn(live)]], renewing: true)
        let key = try await rig.save(testLogin(.codex, "e"), origin: .kept)
        await rig.poller.runBatch()
        let saved = try #require(await entry(rig, key))
        #expect(saved.payloadBytes == live.bytes)
        #expect(saved.origin == .syncBack)
        #expect(saved.kept)
        #expect(rig.tokenRequests.isEmpty)
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.generation == 2)
    }

    @Test func `REQ/F04-AC-4.c24 a live refresh syncs back Codex and agy`() async throws {
        let codex = refreshed(.codex, "e", "r1"), agy = refreshed(.agy, "g", "r1")
        let rig = try PollerRig(live: [.codex: [.signedIn(codex)], .agy: [.signedIn(agy)]])
        let codexKey = try await rig.save(testLogin(.codex, "e"))
        let agyKey = try await rig.save(testLogin(.agy, "g"))
        await rig.poller.reloadVault()
        await rig.poller.refreshLive()
        #expect(await entry(rig, codexKey)?.payloadBytes == codex.bytes)
        #expect(await entry(rig, agyKey)?.payloadBytes == agy.bytes)
    }

    @Test func `opening the popover re-reads live logins and syncs back Codex and agy without a request`() async throws {
        let codex = refreshed(.codex, "e", "r1"), fresh = testLogin(.claude, "n")
        let rig = try PollerRig(live: [.claude: [.signedIn(fresh)], .codex: [.signedIn(codex)]])
        let codexKey = try await rig.save(testLogin(.codex, "e"))
        await rig.poller.reloadVault()
        await rig.poller.rereadLive()
        #expect(rig.state.live[.claude] == .signedIn(fresh))
        #expect(await entry(rig, codexKey)?.payloadBytes == codex.bytes)
        #expect(rig.tags.isEmpty)
    }

    @Test func `REQ/F04-AC-4.c24 nothing is written when the in-section read no longer matches or the entry is unreadable`() async throws {
        let first = refreshed(.codex, "e", "r1")
        let rig = try PollerRig(live: [.codex: [.signedIn(first), .signedIn(testLogin(.codex, "x"))]])
        let key = try await rig.save(testLogin(.codex, "e"))
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.generation == 1)

        let same = try PollerRig(live: [.codex: [.signedIn(refreshed(.codex, "e", "r1")), .signedIn(testLogin(.codex, "e"))]])
        let sameKey = try await same.save(testLogin(.codex, "e"))
        await same.poller.runBatch()
        #expect(await entry(same, sameKey)?.generation == 1)

        let bad = try PollerRig(live: [.codex: [.signedIn(refreshed(.codex, "e", "r1"))]])
        let badKey = testKey(testLogin(.codex, "e"))
        try bad.box.write("support/vault/codex/\(badKey.id).json", "{}")
        await bad.poller.runBatch()
        #expect(try Data(contentsOf: bad.box.supportRoot.appending(path: "vault/codex/\(badKey.id).json")) == Data("{}".utf8))
    }

    @Test func `REQ/F04-AC-4.c24 an unsaved live login is never written by a sync-back`() async throws {
        let rig = try PollerRig(live: [.codex: [.signedIn(testLogin(.codex, "e"))]])
        await rig.poller.runBatch()
        #expect(await rig.vault.entries(.codex).isEmpty)
    }

    // MARK: F04-AC-4.c25

    @Test func `REQ/F04-AC-4.c25 Claude syncs back only when two interval batches agree`() async throws {
        let live = refreshed(.claude, "a", "r1")
        let rig = try PollerRig(live: [.claude: [.signedIn(live)]])
        let key = try await rig.save(testLogin(.claude, "a"))
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.generation == 1)
        rig.clock.advance(300)
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.payloadBytes == live.bytes)
        #expect(await entry(rig, key)?.origin == .syncBack)
    }

    @Test func `REQ/F04-AC-4.c25 a Claude in-section read that differs from the previous batch writes nothing`() async throws {
        let r1 = refreshed(.claude, "a", "r1"), r2 = refreshed(.claude, "a", "r2")
        let rig = try PollerRig(live: [.claude: [.signedIn(r1)]])
        let key = try await rig.save(testLogin(.claude, "a"))
        await rig.poller.runBatch()
        rig.tools[.claude]!.script([.signedIn(r1), .signedIn(r2)])
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.generation == 1)
        rig.tools[.claude]!.script([.signedIn(r2)])
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.generation == 1)
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.payloadBytes == r2.bytes)
    }

    @Test func `REQ/F04-AC-4.c25 on-demand refreshes neither sync back Claude nor move its baseline`() async throws {
        let r1 = refreshed(.claude, "a", "r1"), r2 = refreshed(.claude, "a", "r2")
        let rig = try PollerRig(live: [.claude: [.signedIn(r1)]])
        let key = try await rig.save(testLogin(.claude, "a"))
        await rig.poller.runBatch()
        await rig.poller.refreshLive()
        await rig.poller.refresh(key)
        #expect(await entry(rig, key)?.generation == 1)
        rig.tools[.claude]!.script([.signedIn(r2)])
        await rig.poller.refreshLive()
        rig.clock.advance(300)
        rig.tools[.claude]!.script([.signedIn(r1)])
        await rig.poller.runBatch()
        #expect(await entry(rig, key)?.payloadBytes == r1.bytes)
    }

    @Test func `REQ/F04-AC-4.c25 unknown, unsupported and incomplete live states never sync back`() async throws {
        for state: LiveState in [.unknown("timed out"), .unsupported("keyring"), .signedIn(testLogin(.codex, "e", complete: false))] {
            let rig = try PollerRig(live: [.codex: [state]])
            let key = try await rig.save(testLogin(.codex, "e"))
            await rig.poller.runBatch()
            await rig.poller.refreshLive()
            #expect(await entry(rig, key)?.generation == 1)
        }
        let claude = try PollerRig(live: [.claude: [.signedIn(refreshed(.claude, "a", "r1")), .unknown("x"), .signedIn(refreshed(.claude, "a", "r1"))]])
        let key = try await claude.save(testLogin(.claude, "a"))
        await claude.poller.runBatch()
        await claude.poller.runBatch()
        #expect(await entry(claude, key)?.generation == 1)
    }

    @Test func `a sync-back clears a needs sign-in mark`() async throws {
        let soon = Date(timeIntervalSince1970: 1_790_000_000 + 60)
        let rig = try PollerRig(renewing: true) { request in
            isTokenRequest(request) ? .json(400, #"{"error":"invalid_grant"}"#) : okReply(request)
        }
        let key = try await rig.save(testLogin(.codex, "e", expiry: soon))
        await rig.poller.runBatch()
        #expect(rig.state.status[key]?.flag == .needsSignIn)
        rig.tools[.codex]!.script([.signedIn(refreshed(.codex, "e", "r1"))])
        rig.clock.advance(300)
        await rig.poller.runBatch()
        #expect(rig.state.status[key]?.flag == .ok)
    }
}
