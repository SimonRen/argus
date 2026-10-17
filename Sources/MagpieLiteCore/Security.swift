import Foundation

/// How one run of `/usr/bin/security` ended.
public enum SecurityOutcome: Sendable, Equatable {
    case exited(status: Int32, stdout: Data, stderr: Data)
    /// The child was killed after the timeout.
    case timedOut
    case launchFailed(String)
}

public protocol SecurityRunning: Sendable {
    /// Runs `/usr/bin/security` with `arguments`; writes `stdin` (when non-nil) and closes it; kills the child after `timeout`.
    func run(arguments: [String], stdin: Data?, timeout: Duration) async -> SecurityOutcome
}

/// The real `security` tool, run as a child process with a watchdog.
public struct SecurityCLI: SecurityRunning {
    let executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security")) {
        self.executable = executable
    }

    public func run(arguments: [String], stdin: Data?, timeout: Duration) async -> SecurityOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        let state = ChildState()
        let done = DispatchGroup()
        done.enter()
        process.terminationHandler = { _ in done.leave() }
        do {
            try process.run()
        } catch {
            return .launchFailed("could not start security")
        }
        let pid = process.processIdentifier
        for (pipe, isOut) in [(out, true), (err, false)] {
            done.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                state.set(data, stdout: isOut)
                done.leave()
            }
        }
        if let input, let stdin {
            let handle = input.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)   // a child that exits early must not kill the app
            try? handle.write(contentsOf: stdin)
            try? handle.close()
        }
        let c = timeout.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if state.markTimedOutIfRunning() { kill(pid, SIGKILL) }
        }
        return await withCheckedContinuation { cont in
            done.notify(queue: .global()) {
                let r = state.finish()
                cont.resume(returning: r.timedOut ? .timedOut
                    : .exited(status: process.terminationStatus, stdout: r.out, stderr: r.err))
            }
        }
    }
}

private final class ChildState: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private var finished = false, timedOut = false

    func set(_ data: Data, stdout: Bool) {
        lock.withLock { if stdout { out = data } else { err = data } }
    }

    func markTimedOutIfRunning() -> Bool {
        lock.withLock {
            if finished { return false }
            timedOut = true
            return true
        }
    }

    func finish() -> (out: Data, err: Data, timedOut: Bool) {
        lock.withLock {
            finished = true
            return (out, err, timedOut)
        }
    }
}

public enum KeychainRead: Sendable, Equatable { case found(Data), notFound, unknown(String) }
public enum KeychainWrite: Sendable, Equatable { case written, failed(String) }
public enum KeychainTransport: Sendable, Equatable { case stdin(String), argv([String]) }

/// Generic-password items through `security`. Reasons name statuses only, never item contents.
public struct Keychain: Sendable {
    /// Bytes of one `security -i` command line, its "\n" included.
    public static let stdinLineLimit = 4032

    let target: KeychainTarget
    let runner: any SecurityRunning
    let timeout: Duration

    public init(target: KeychainTarget, runner: any SecurityRunning, timeout: Duration = .seconds(20)) {
        self.target = target
        self.runner = runner
        self.timeout = timeout
    }

    public func read(service: String, account: String) async -> KeychainRead {
        if fileMissing { return .unknown("keychain file missing") }
        let outcome = await runner.run(arguments: ["find-generic-password", "-s", service, "-a", account, "-w"] + Self.pathWords(target),
                                       stdin: nil, timeout: timeout)
        switch outcome {
        case .exited(0, let stdout, _):
            return .found(stdout.last == 0x0A ? stdout.dropLast() : stdout)
        case .exited(44, _, _):
            return .notFound
        default:
            return .unknown(Self.reason(outcome))
        }
    }

    public func write(service: String, account: String, value: Data) async -> KeychainWrite {
        if fileMissing { return .failed("keychain file missing") }
        let outcome = switch Self.transport(service: service, account: account, value: value, target: target) {
        case .stdin(let line): await runner.run(arguments: ["-i"], stdin: Data((line + "\n").utf8), timeout: timeout)
        case .argv(let words): await runner.run(arguments: words, stdin: nil, timeout: timeout)
        }
        if case .exited(0, _, _) = outcome { return .written }
        return .failed(Self.reason(outcome))
    }

    public func delete(service: String, account: String) async -> KeychainWrite {
        if fileMissing { return .failed("keychain file missing") }
        let outcome = await runner.run(arguments: ["delete-generic-password", "-s", service, "-a", account] + Self.pathWords(target),
                                       stdin: nil, timeout: timeout)
        switch outcome {
        case .exited(0, _, _), .exited(44, _, _): return .written
        default: return .failed(Self.reason(outcome))
        }
    }

    /// The `add-generic-password` command for `value`: plain text `-w` when no byte needs quoting, else `-X` hex;
    /// one `security -i` line unless that line is over `stdinLineLimit`, then argv.
    public static func transport(service: String, account: String, value: Data, target: KeychainTarget) -> KeychainTransport {
        var words = ["add-generic-password", "-U", "-a", account, "-s", service]
        if let text = String(data: value, encoding: .utf8), value.allSatisfy(isPlain) {
            words += ["-w", text]
        } else {
            words += ["-X", value.map { String(format: "%02x", $0) }.joined()]
        }
        words += pathWords(target)
        let line = words.map(quoted).joined(separator: " ")
        return line.utf8.count + 1 > stdinLineLimit ? .argv(words) : .stdin(line)
    }

    private var fileMissing: Bool {
        if case .file(let url) = target { return !FileManager.default.fileExists(atPath: url.path) }
        return false
    }

    private static func pathWords(_ target: KeychainTarget) -> [String] {
        if case .file(let url) = target { return [url.path] }
        return []
    }

    private static func isPlain(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
        default: "+/=:._-".utf8.contains(byte)
        }
    }

    private static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { $0 == " " || $0 == "\"" || $0 == "\\" }) else { return word }
        return "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func reason(_ outcome: SecurityOutcome) -> String {
        switch outcome {
        case .exited(let status, _, _): "security exited with status \(status)"
        case .timedOut: "security timed out"
        case .launchFailed(let why): "security did not run (\(why))"
        }
    }
}
