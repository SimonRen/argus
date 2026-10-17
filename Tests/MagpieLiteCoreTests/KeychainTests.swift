import Foundation
import Testing
import MagpieLiteCore

@Suite struct KeychainTests {
    // MARK: F01-AC-1.c4 — rc 44, other failures, timeout

    @Test func `REQ/F01-AC-1.c4 security rc 44 shows not signed in`() async throws {
        let fake = ScriptedSecurity([.exited(status: 44, stdout: Data(), stderr: Data())])
        let box = try TestSandbox(security: fake)
        let state = await ClaudeTool(env: box.env).readLive()
        #expect(state == .notSignedIn)
        #expect(state.statusText(.claude) == "Not signed in")
        #expect(state.allowsSwitch)
    }

    @Test func `REQ/F01-AC-1.c4 any other non-zero rc makes the live state unknown with switching disabled and a retry notice`() async throws {
        for tool in Tool.allCases {
            let fake = ScriptedSecurity([.exited(status: 51, stdout: Data(), stderr: utf8("boom"))])
            let box = try TestSandbox(security: fake)
            let state: LiveState = switch tool {
            case .claude: await ClaudeTool(env: box.env).readLive()
            case .codex: await { () async -> LiveState in
                try? box.write("codex/config.toml", "cli_auth_credentials_store = \"auto\"\n")
                return await CodexTool(env: box.env).readLive()
            }()
            case .agy: await AgyTool(env: box.env).readLive()
            }
            guard case .unknown = state else { Issue.record("\(tool) read \(state)"); continue }
            #expect(!state.allowsSwitch)
            #expect(state.statusText(tool) == "\(tool.displayName)'s login can't be read right now — retry")
        }
    }

    @Test func `REQ/F01-AC-1.c4 a security timeout makes the live state unknown with switching disabled`() async throws {
        let fake = ScriptedSecurity([.timedOut])
        let box = try TestSandbox(security: fake)
        let state = await AgyTool(env: box.env).readLive()
        guard case .unknown = state else { Issue.record("read \(state)"); return }
        #expect(!state.allowsSwitch)
        #expect(state.statusText(.agy) == "Antigravity CLI's login can't be read right now — retry")
    }

    @Test func `REQ/F01-AC-1.c4 Keychain reads run security with a 20 second timeout`() async throws {
        let fake = ScriptedSecurity([.exited(status: 44, stdout: Data(), stderr: Data())])
        let box = try TestSandbox(security: fake)
        _ = await box.keychain.read(service: "svc", account: "acct")
        _ = await box.keychain.write(service: "svc", account: "acct", value: utf8("v"))
        #expect(fake.calls.count == 2)
        #expect(fake.calls.allSatisfy { $0.timeout == .seconds(20) })
    }

    @Test func `REQ/F01-AC-1.c4 the watchdog kills a child that outlives its timeout`() async {
        let start = Date()
        let outcome = await sleepingRunner().run(arguments: ["5"], stdin: nil, timeout: .milliseconds(200))
        #expect(outcome == .timedOut)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func `failure reasons name the status only`() async throws {
        let fake = ScriptedSecurity([.exited(status: 51, stdout: utf8("test-secret-out"), stderr: utf8("test-secret-err"))])
        let box = try TestSandbox(security: fake)
        guard case .unknown(let reason) = await box.keychain.read(service: "svc", account: "acct") else {
            Issue.record("expected unknown"); return
        }
        #expect(!reason.contains("test-secret"))
        guard case .failed(let why) = await box.keychain.write(service: "svc", account: "acct", value: utf8("test-secret-value")) else {
            Issue.record("expected failed"); return
        }
        #expect(!why.contains("test-secret"))
    }

    @Test func `a missing keychain file is refused without running security`() async throws {
        let fake = ScriptedSecurity([.exited(status: 0, stdout: Data(), stderr: Data())])
        let missing = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID().uuidString).keychain-db")
        let keychain = Keychain(target: .file(missing), runner: fake)
        #expect(await keychain.read(service: "s", account: "a") == .unknown("keychain file missing"))
        #expect(await keychain.write(service: "s", account: "a", value: utf8("v")) == .failed("keychain file missing"))
        #expect(await keychain.delete(service: "s", account: "a") == .failed("keychain file missing"))
        #expect(fake.calls.isEmpty)
    }

    // MARK: F01-AC-1.c5 — exactly one trailing newline

    @Test func `REQ/F01-AC-1.c5 exactly one trailing newline is stripped from security -w output`() async throws {
        let cases: [(String, String)] = [("abc\n", "abc"), ("abc\n\n", "abc\n"), ("abc", "abc"), ("\n", "")]
        for (out, expected) in cases {
            let fake = ScriptedSecurity([.exited(status: 0, stdout: utf8(out), stderr: Data())])
            let box = try TestSandbox(security: fake)
            #expect(await box.keychain.read(service: "svc", account: "acct") == .found(utf8(expected)))
            #expect(fake.calls.first?.arguments == ["find-generic-password", "-s", "svc", "-a", "acct", "-w", box.keychainURL.path])
        }
    }

    @Test func `REQ/F01-AC-1.c5 a live login read with a trailing newline parses`() async throws {
        let value = #"{"claudeAiOauth":{"accessToken":"test-access-1","refreshToken":"test-refresh-1","expiresAt":1790000000000}}"#
        let fake = ScriptedSecurity([.exited(status: 0, stdout: utf8(value + "\n"), stderr: Data())])
        let box = try TestSandbox(security: fake)
        guard case .signedIn(let login) = await ClaudeTool(env: box.env).readLive() else { Issue.record("not signed in"); return }
        #expect(login.bytes == utf8(value))
    }

    // MARK: F03-AC-3.c16 — transport and byte-exact read-back

    @Test func `REQ/F03-AC-3.c16 a value that needs no quoting goes as -w text over security -i and reads back exactly`() async throws {
        let box = try TestSandbox()
        let value = utf8("go-keyring-base64:" + String(repeating: "QUJDRA==", count: 275))
        guard case .stdin(let line) = Keychain.transport(service: "gemini", account: "antigravity", value: value, target: box.env.keychain) else {
            Issue.record("expected stdin"); return
        }
        #expect(line.contains(" -w go-keyring-base64:"))
        #expect(await box.keychain.write(service: "gemini", account: "antigravity", value: value) == .written)
        #expect(box.guarded?.calls.last?.viaStdin == true)
        #expect(await box.keychain.read(service: "gemini", account: "antigravity") == .found(value))
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F03-AC-3.c16 a value that needs quoting goes as -X hex over security -i and reads back exactly`() async throws {
        let box = try TestSandbox()
        let padding = String(repeating: "x", count: 1300)
        let value = utf8(#"{"claudeAiOauth":{"accessToken":"test-access-1","refreshToken":"test-refresh-1","expiresAt":1790000000000,"scopes":["user:inference","user:profile"],"subscriptionType":"max","note":"a \"quoted\" \\ \#(padding)"}}"#)
        let transport = Keychain.transport(service: "Claude Code-credentials", account: "tester", value: value, target: box.env.keychain)
        guard case .stdin(let line) = transport else { Issue.record("expected stdin"); return }
        let hex = value.map { String(format: "%02x", $0) }.joined()
        #expect(line == "add-generic-password -U -a tester -s \"Claude Code-credentials\" -X \(hex) \(box.keychainURL.path)")
        #expect(await box.keychain.write(service: "Claude Code-credentials", account: "tester", value: value) == .written)
        #expect(box.guarded?.calls.last?.viaStdin == true)
        #expect(await box.keychain.read(service: "Claude Code-credentials", account: "tester") == .found(value))
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F03-AC-3.c16 a command line over 4032 bytes goes in argv and reads back exactly`() async throws {
        let box = try TestSandbox()
        let value = utf8("{\"blob\":\"" + String(repeating: "y", count: 4985) + "\"}")
        #expect(value.count >= 4990)
        guard case .argv(let words) = Keychain.transport(service: "svc", account: "acct", value: value, target: box.env.keychain) else {
            Issue.record("expected argv"); return
        }
        #expect(words.first == "add-generic-password")
        #expect(words.last == box.keychainURL.path)
        #expect(await box.keychain.write(service: "svc", account: "acct", value: value) == .written)
        #expect(box.guarded?.calls.last?.viaStdin == false)
        #expect(await box.keychain.read(service: "svc", account: "acct") == .found(value))
        #expect(box.violations.isEmpty)
    }

    @Test func `REQ/F03-AC-3.c16 the stdin line limit counts the newline`() {
        let target = KeychainTarget.file(URL(fileURLWithPath: "/k"))
        let fixed = "add-generic-password -U -a a -s s -w  /k".utf8.count
        let fits = utf8(String(repeating: "z", count: Keychain.stdinLineLimit - 1 - fixed))
        let over = utf8(String(repeating: "z", count: Keychain.stdinLineLimit - fixed))
        guard case .stdin(let line) = Keychain.transport(service: "s", account: "a", value: fits, target: target) else {
            Issue.record("expected stdin"); return
        }
        #expect(line.utf8.count + 1 == Keychain.stdinLineLimit)
        #expect(Keychain.transport(service: "s", account: "a", value: over, target: target) == .argv(
            ["add-generic-password", "-U", "-a", "a", "-s", "s", "-w", String(decoding: over, as: UTF8.self), "/k"]))
    }

    @Test func `delete removes an item and treats a missing one as done`() async throws {
        let box = try TestSandbox()
        #expect(await box.keychain.write(service: "svc", account: "acct", value: utf8("v1")) == .written)
        #expect(await box.keychain.delete(service: "svc", account: "acct") == .written)
        #expect(await box.keychain.read(service: "svc", account: "acct") == .notFound)
        #expect(await box.keychain.delete(service: "svc", account: "acct") == .written)
        #expect(box.violations.isEmpty)
    }

    @Test func `the guard refuses a call not addressed to the disposable keychain`() async throws {
        let box = try TestSandbox()
        let outcome = await box.env.security.run(arguments: ["find-generic-password", "-s", "svc", "-a", "acct", "-w"], stdin: nil, timeout: .seconds(5))
        #expect(outcome == .launchFailed("sandbox refused"))
        #expect(box.violations.count == 1)
    }
}
