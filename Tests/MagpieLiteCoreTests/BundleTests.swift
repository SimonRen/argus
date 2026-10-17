import Foundation
import Testing
import MagpieLiteCore

/// Package root: three levels above this file (`Tests/MagpieLiteCoreTests/BundleTests.swift`).
fileprivate func packageRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

fileprivate struct RunResult {
    let status: Int32
    let output: String
}

/// Runs a tool to completion with output captured in a file, so a long build never fills a pipe.
/// The child inherits this process's environment (and so its `PATH`).
fileprivate func run(_ executable: String, _ arguments: [String], in directory: URL, logDir: URL) async throws -> RunResult {
    let logURL = logDir.appendingPathComponent("\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = log
    process.standardError = log
    process.standardInput = FileHandle.nullDevice

    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { finished in
            continuation.resume(returning: finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    return RunResult(status: status, output: output)
}

fileprivate func tail(_ text: String, lines: Int = 40) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
}

@Suite(.serialized)
struct BundleTests {
    @Test(.timeLimit(.minutes(15)))
    func `REQ/F05-AC-5.c6 make build produces a signed menubar-only app bundle`() async throws {
        let fm = FileManager.default
        let root = packageRoot()
        let out = fm.temporaryDirectory.appendingPathComponent("magpie-bundle-\(UUID().uuidString)", isDirectory: true)
        let logs = fm.temporaryDirectory.appendingPathComponent("magpie-bundle-logs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: out)
            try? fm.removeItem(at: logs)
        }

        let scratch = root.appendingPathComponent(".build-bundle-test", isDirectory: true)
        let build = try await run(
            "/usr/bin/make",
            ["build", "SCRATCH=\(scratch.path)", "OUT=\(out.path)"],
            in: root,
            logDir: logs
        )
        try #require(build.status == 0, "make build exited \(build.status):\n\(tail(build.output))")

        let app = out.appendingPathComponent("MagpieLite.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)

        // The executable.
        let executable = contents.appendingPathComponent("MacOS/MagpieLite")
        var isDirectory: ObjCBool = false
        let executableExists = fm.fileExists(atPath: executable.path, isDirectory: &isDirectory)
        #expect(executableExists && !isDirectory.boolValue && fm.isExecutableFile(atPath: executable.path),
                "Contents/MacOS/MagpieLite is not an executable file")

        // The icon.
        let icon = contents.appendingPathComponent("Resources/AppIcon.icns")
        var iconIsDirectory: ObjCBool = false
        let iconExists = fm.fileExists(atPath: icon.path, isDirectory: &iconIsDirectory)
        #expect(iconExists && !iconIsDirectory.boolValue, "Contents/Resources/AppIcon.icns is missing")

        // Info.plist with LSUIElement true.
        let plistURL = contents.appendingPathComponent("Info.plist")
        let plistData = try #require(fm.contents(atPath: plistURL.path), "Contents/Info.plist is missing")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
            "Contents/Info.plist is not a dictionary"
        )
        #expect((plist["LSUIElement"] as? Bool) == true, "LSUIElement is not true")

        // The signature verifies.
        let verify = try await run("/usr/bin/codesign", ["--verify", app.path], in: root, logDir: logs)
        #expect(verify.status == 0, "codesign --verify exited \(verify.status):\n\(tail(verify.output))")
    }
}
