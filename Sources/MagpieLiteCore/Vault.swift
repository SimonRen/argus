import Foundation

public enum VaultOrigin: String, Codable, Sendable { case save, syncBack, kept, renewal, undo }

/// One saved login: the exact live bytes (base64) plus the identity snapshot they were saved under.
public struct VaultEnvelope: Codable, Sendable, Equatable {
    public let v: Int
    public let tool: Tool
    public let identity: Identity
    public let identityKey: String
    public let label: String
    public let plan: String?
    /// Claude: the `oauthAccount` JSON text.
    public let claudeAccount: String?
    /// Codex `chatgpt_account_id`.
    public let accountID: String?
    /// Base64 of the exact live bytes.
    public let payload: String
    /// 1 on create, +1 per rewrite.
    public let generation: Int
    public let capturedAt: Date
    public let origin: VaultOrigin
    public let kept: Bool
    /// agy id_token `azp`.
    public let clientId: String?

    public var payloadBytes: Data? { Data(base64Encoded: payload) }

    func with(payload: String, generation: Int, capturedAt: Date, origin: VaultOrigin, kept: Bool) -> VaultEnvelope {
        VaultEnvelope(v: v, tool: tool, identity: identity, identityKey: identityKey, label: label, plan: plan,
                      claudeAccount: claudeAccount, accountID: accountID, payload: payload, generation: generation,
                      capturedAt: capturedAt, origin: origin, kept: kept, clientId: clientId)
    }
}

public enum VaultEntry: Sendable, Equatable {
    case valid(VaultEnvelope)
    case unreadable(tool: Tool, id: String, reason: String)

    /// File stem = `identity.fileID`.
    public var id: String {
        switch self {
        case .valid(let e): sha256Hex(Data(e.identityKey.utf8))
        case .unreadable(_, let id, _): id
        }
    }

    public var tool: Tool {
        switch self {
        case .valid(let e): e.tool
        case .unreadable(let tool, _, _): tool
        }
    }
}

/// Never carries a credential value.
public struct VaultError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// A removed entry's raw file bytes, kept in memory for undo.
public struct RemovedEntry: Sendable, Equatable {
    public let tool: Tool
    public let id: String
    public let bytes: Data
}

public struct VaultFaults: Sendable {
    public var failAfterStagedWrite: Bool
    public init(failAfterStagedWrite: Bool = false) { self.failAfterStagedWrite = failAfterStagedWrite }
}

/// Owner-only files under `supportRoot/vault/<tool>/<id>.json`, written through a staged file and `rename(2)`.
public actor Vault {
    public nonisolated let vaultURL: URL
    let now: @Sendable () -> Date
    let faults: VaultFaults
    private var tails: [Tool: Task<Void, Never>] = [:]

    public init(supportRoot: URL, now: @escaping @Sendable () -> Date = { Date() }, faults: VaultFaults = VaultFaults()) throws {
        vaultURL = supportRoot.appending(path: "vault", directoryHint: .isDirectory)
        self.now = now
        self.faults = faults
        try Self.makeOwnerOnlyFolder(vaultURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = vaultURL
        try url.setResourceValues(values)
        for tool in Tool.allCases {
            let dir = vaultURL.appending(path: tool.rawValue, directoryHint: .isDirectory)
            try Self.makeOwnerOnlyFolder(dir)
            Self.settleStagedFiles(in: dir)
        }
    }

    public func entries(_ tool: Tool) -> [VaultEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(tool).path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.dropLast(5).contains(".") }
            .map { String($0.dropLast(5)) }
            .sorted()
            .compactMap { entry(tool, id: $0) }
    }

    public func entry(_ tool: Tool, id: String) -> VaultEntry? {
        guard let data = try? Data(contentsOf: file(tool, id)) else { return nil }
        return Self.validate(data, tool: tool, id: id)
    }

    @discardableResult
    public func save(_ state: LiveState, origin: VaultOrigin = .save, allowIncomplete: Bool = false) throws -> VaultEnvelope {
        let login: LiveLogin
        switch state {
        case .signedIn(let l): login = l
        case .notSignedIn: throw VaultError("not signed in")
        case .wiped: throw VaultError("signed out")
        case .unknown: throw VaultError("can't be read")
        case .unsupported: throw VaultError("unsupported storage mode")
        }
        guard login.identity.isComplete || allowIncomplete else { throw VaultError("incomplete identity") }
        let tool = login.identity.tool
        let id = login.identity.fileID
        let existing = try existingEnvelope(tool, id)
        let envelope = VaultEnvelope(
            v: 1, tool: tool, identity: login.identity, identityKey: login.identity.key, label: login.label, plan: login.plan,
            claudeAccount: login.claudeAccount.map { String(decoding: $0, as: UTF8.self) }, accountID: login.accountID,
            payload: login.bytes.base64EncodedString(), generation: (existing?.generation ?? 0) + 1, capturedAt: now(),
            origin: origin, kept: Self.kept(origin, existing), clientId: login.clientID)
        try stagedWrite(Self.encode(envelope), to: file(tool, id))
        return envelope
    }

    @discardableResult
    public func replacePayload(_ tool: Tool, id: String, bytes: Data, origin: VaultOrigin) throws -> VaultEnvelope {
        guard let existing = try existingEnvelope(tool, id) else { throw VaultError("no saved login with that id") }
        let envelope = existing.with(payload: bytes.base64EncodedString(), generation: existing.generation + 1,
                                     capturedAt: now(), origin: origin, kept: Self.kept(origin, existing))
        try stagedWrite(Self.encode(envelope), to: file(tool, id))
        return envelope
    }

    public func remove(_ tool: Tool, id: String) throws -> RemovedEntry {
        let target = file(tool, id)
        guard let bytes = try? Data(contentsOf: target) else { throw VaultError("no saved login with that id") }
        try FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: Self.prev(target))
        return RemovedEntry(tool: tool, id: id, bytes: bytes)
    }

    /// Writes the removed bytes back unchanged; false (nothing written) when an entry with that id exists.
    public func restore(_ removed: RemovedEntry) throws -> Bool {
        let target = file(removed.tool, removed.id)
        if FileManager.default.fileExists(atPath: target.path) { return false }
        try stagedWrite(removed.bytes, to: target)
        return true
    }

    /// Runs `body` after every earlier body for `tool` has finished, to completion even if the caller is cancelled.
    public func exclusive<T: Sendable>(_ tool: Tool, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tails[tool]
        let task = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        tails[tool] = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - Files

    private func folder(_ tool: Tool) -> URL { vaultURL.appending(path: tool.rawValue, directoryHint: .isDirectory) }
    private func file(_ tool: Tool, _ id: String) -> URL { folder(tool).appending(path: "\(id).json") }
    private static func prev(_ target: URL) -> URL { target.appendingPathExtension("prev") }

    /// The current valid envelope, nil when there is none; throws for an unreadable one, which is never overwritten.
    private func existingEnvelope(_ tool: Tool, _ id: String) throws -> VaultEnvelope? {
        switch entry(tool, id: id) {
        case nil: nil
        case .valid(let e): e
        case .unreadable: throw VaultError("unreadable vault entry")
        }
    }

    private static func kept(_ origin: VaultOrigin, _ existing: VaultEnvelope?) -> Bool {
        switch origin {
        case .kept: true
        case .save: false
        case .syncBack, .renewal, .undo: existing?.kept ?? false
        }
    }

    private func stagedWrite(_ data: Data, to target: URL) throws {
        guard let staged = writeStagedFile(data, besides: target) else { throw VaultError("can't write the vault file") }
        if faults.failAfterStagedWrite { throw VaultError("vault write interrupted") }
        try Self.commit(staged, to: target)
    }

    /// Clones the current file to `.prev`, then renames the staged file over it.
    private static func commit(_ staged: URL, to target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            let prev = prev(target)
            try? fm.removeItem(at: prev)
            try fm.copyItem(at: target, to: prev)
        }
        guard rename(staged.path, target.path) == 0 else {
            unlink(staged.path)
            throw VaultError("can't replace the vault file (errno \(errno))")
        }
    }

    // MARK: - Launch housekeeping

    private static func makeOwnerOnlyFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// A staged file left by an interrupted write is promoted when it is a newer generation than its target (or the
    /// target is gone); any other staged file is deleted.
    private static func settleStagedFiles(in dir: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(".tmp") {
            let staged = dir.appending(path: name)
            guard let range = name.range(of: ".json.") else { unlink(staged.path); continue }
            let id = String(name[..<range.lowerBound])
            let target = dir.appending(path: "\(id).json")
            guard let data = try? Data(contentsOf: staged),
                  case .valid(let candidate) = validate(data, tool: Tool(rawValue: dir.lastPathComponent) ?? .claude, id: id) else {
                unlink(staged.path); continue
            }
            let current = (try? Data(contentsOf: target)).flatMap { try? decoder.decode(VaultEnvelope.self, from: $0) }
            if current == nil || candidate.generation > current!.generation {
                try? commit(staged, to: target)
            } else {
                unlink(staged.path)
            }
        }
    }

    // MARK: - Encoding

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func encode(_ envelope: VaultEnvelope) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(envelope)
    }

    static func validate(_ data: Data, tool: Tool, id: String) -> VaultEntry {
        guard let envelope = try? decoder.decode(VaultEnvelope.self, from: data) else {
            return .unreadable(tool: tool, id: id, reason: "not a vault envelope")
        }
        guard envelope.v == 1 else { return .unreadable(tool: tool, id: id, reason: "unsupported version") }
        guard envelope.tool == tool else { return .unreadable(tool: tool, id: id, reason: "saved under another tool") }
        guard sha256Hex(Data(envelope.identityKey.utf8)) == id else { return .unreadable(tool: tool, id: id, reason: "file name mismatch") }
        guard envelope.payloadBytes != nil else { return .unreadable(tool: tool, id: id, reason: "payload is not base64") }
        return .valid(envelope)
    }
}

/// Writes `data` to a new 0600 file beside `target` (`<name>.<random>.tmp`, `O_EXCL`) and flushes it to disk with
/// `F_FULLFSYNC`; nil (nothing left behind) when any step fails.
func writeStagedFile(_ data: Data, besides target: URL) -> URL? {
    let staged = target.deletingLastPathComponent()
        .appending(path: "\(target.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
    let fd = open(staged.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    var ok = fchmod(fd, 0o600) == 0
    ok = ok && data.withUnsafeBytes { buf in
        var offset = 0
        while offset < buf.count {
            let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    ok = ok && fcntl(fd, F_FULLFSYNC) == 0
    close(fd)
    if !ok { unlink(staged.path) }
    return ok ? staged : nil
}

/// Replaces `target` with `data` atomically: staged 0600 file, fsync, `rename(2)`.
func writeFileAtomically(_ data: Data, to target: URL) -> Bool {
    guard let staged = writeStagedFile(data, besides: target) else { return false }
    guard rename(staged.path, target.path) == 0 else {
        unlink(staged.path)
        return false
    }
    return true
}

/// Single-instance guard: a non-blocking exclusive `flock` on `vault/.lock`, released on deinit.
public final class InstanceLock: Sendable {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func acquire(supportRoot: URL) -> InstanceLock? {
        let dir = supportRoot.appending(path: "vault", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(dir.appending(path: ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return InstanceLock(fd: fd)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
