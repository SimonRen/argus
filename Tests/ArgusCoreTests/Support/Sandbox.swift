import Foundation
import ArgusCore

/// A fresh temp folder (home stand-in, Codex home, support root) and, unless the test scripts `security`, a
/// disposable keychain file. Nothing in it can reach the owner's home folder or login keychain.
final class TestSandbox: @unchecked Sendable {
    let root: URL
    let home: URL
    let codexHome: URL
    let supportRoot: URL
    let keychainURL: URL
    /// The guard every real `security` call goes through; nil when the test scripts `security`.
    let guarded: TestGuardedSecurity?
    let env: ToolEnvironment

    /// `security` given: no keychain is created; the keychain path is an empty placeholder file the fake never opens.
    init(security scripted: (any SecurityRunning)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "argus-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        codexHome = root.appending(path: "codex", directoryHint: .isDirectory)
        supportRoot = root.appending(path: "support", directoryHint: .isDirectory)
        keychainURL = root.appending(path: "t.keychain-db")
        for dir in [home, codexHome, supportRoot] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let security: any SecurityRunning
        if let scripted {
            FileManager.default.createFile(atPath: keychainURL.path, contents: Data())
            guarded = nil
            security = scripted
        } else {
            try Self.runSecurity(["create-keychain", "-p", "test-keychain-pw", keychainURL.path])
            guard FileManager.default.fileExists(atPath: keychainURL.path) else { throw SandboxError.keychainNotCreated }
            let g = TestGuardedSecurity(keychain: keychainURL)
            guarded = g
            security = g
        }
        env = ToolEnvironment(home: home, codexHome: codexHome, user: "tester", keychain: .file(keychainURL), security: security)
    }

    deinit {
        // delete-keychain is only ever given the disposable file, and only while it exists.
        if guarded != nil, FileManager.default.fileExists(atPath: keychainURL.path) {
            try? Self.runSecurity(["delete-keychain", keychainURL.path])
        }
        try? FileManager.default.removeItem(at: root)
    }

    var keychain: Keychain { Keychain(target: env.keychain, runner: env.security) }

    /// Calls the guard refused; a test that reaches the real tool ends by expecting this empty.
    var violations: [String] { guarded?.violations ?? [] }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> Data? {
        try? Data(contentsOf: root.appending(path: path))
    }

    private static func runSecurity(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SandboxError.securityFailed(p.terminationStatus) }
    }

    enum SandboxError: Error { case keychainNotCreated, securityFailed(Int32) }
}

/// Runs the real `security` tool only for `find-`/`add-`/`delete-generic-password` addressed to the disposable
/// keychain (its path the last word, the file present at call time) — a missing path would make `security` write
/// the login keychain. Everything else is refused and recorded.
final class TestGuardedSecurity: SecurityRunning, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let words: [String]
        let viaStdin: Bool
    }

    let keychain: URL
    private let inner = SecurityCLI()
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var refused: [String] = []

    init(keychain: URL) {
        self.keychain = keychain
    }

    var calls: [Call] { lock.withLock { recorded } }
    var violations: [String] { lock.withLock { refused } }

    func run(arguments: [String], stdin: Data?, timeout: Duration) async -> SecurityOutcome {
        var words = arguments
        var viaStdin = false
        if arguments == ["-i"] {
            guard let stdin, let text = String(data: stdin, encoding: .utf8), text.hasSuffix("\n"),
                  !text.dropLast().contains("\n"), let parsed = splitCommandLine(String(text.dropLast())) else {
                return refuse("-i with anything but one command line")
            }
            words = parsed
            viaStdin = true
        } else if stdin != nil {
            return refuse("stdin outside -i")
        }
        let verbs = ["find-generic-password", "add-generic-password", "delete-generic-password"]
        guard let verb = words.first, verbs.contains(verb) else { return refuse("verb \(words.first ?? "")") }
        guard words.last == keychain.path, FileManager.default.fileExists(atPath: keychain.path) else {
            return refuse("\(verb) not addressed to the disposable keychain")
        }
        lock.withLock { recorded.append(Call(words: words, viaStdin: viaStdin)) }
        return await inner.run(arguments: arguments, stdin: stdin, timeout: timeout)
    }

    private func refuse(_ why: String) -> SecurityOutcome {
        lock.withLock { refused.append(why) }
        return .launchFailed("sandbox refused")
    }
}

/// Words of one `security -i` line: double quotes group, `\` escapes inside them. nil when a quote is unclosed.
func splitCommandLine(_ line: String) -> [String]? {
    var words: [String] = [], current = "", inQuotes = false, escaped = false, hasWord = false
    for ch in line {
        if escaped { current.append(ch); escaped = false; continue }
        if inQuotes {
            if ch == "\\" { escaped = true } else if ch == "\"" { inQuotes = false } else { current.append(ch) }
            continue
        }
        if ch == "\"" { inQuotes = true; hasWord = true } else if ch == " " {
            if hasWord { words.append(current); current = ""; hasWord = false }
        } else { current.append(ch); hasWord = true }
    }
    if inQuotes || escaped { return nil }
    if hasWord { words.append(current) }
    return words
}

/// Returns scripted outcomes in order (the last one repeats) and records each call; runs nothing.
final class ScriptedSecurity: SecurityRunning, @unchecked Sendable {
    struct Call: Sendable {
        let arguments: [String]
        let stdin: Data?
        let timeout: Duration
    }

    private let lock = NSLock()
    private var outcomes: [SecurityOutcome]
    private var recorded: [Call] = []

    init(_ outcomes: [SecurityOutcome]) {
        self.outcomes = outcomes
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(arguments: [String], stdin: Data?, timeout: Duration) async -> SecurityOutcome {
        lock.withLock {
            recorded.append(Call(arguments: arguments, stdin: stdin, timeout: timeout))
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
    }
}

/// A child that outlives any short timeout, for the watchdog test.
func sleepingRunner() -> SecurityCLI {
    SecurityCLI(executable: URL(fileURLWithPath: "/bin/sleep"))
}

/// An unsigned JWT with `claims`.
func testJWT(_ claims: [String: Any]) -> String {
    func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = b64url(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
    let body = b64url(try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
    return "\(header).\(body).sig"
}

func utf8(_ s: String) -> Data { Data(s.utf8) }
