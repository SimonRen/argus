import Foundation

public struct ClaudeLockTiming: Sendable {
    /// Total wait for a lock Claude Code holds.
    public var budget: Duration
    public var poll: Duration
    /// `.oauth_refresh.lock` and `.claude.lock`.
    public var refreshStale: TimeInterval
    /// `.claude.json.lock`.
    public var configStale: TimeInterval

    public init(budget: Duration, poll: Duration, refreshStale: TimeInterval, configStale: TimeInterval) {
        self.budget = budget
        self.poll = poll
        self.refreshStale = refreshStale
        self.configStale = configStale
    }

    public static let standard = ClaudeLockTiming(budget: .seconds(9), poll: .milliseconds(250), refreshStale: 60, configStale: 10)
}

/// Claude Code's own lock directories (created with `mkdir`, stale by modification time), taken in Claude Code's order.
struct ClaudeLocks {
    let locks: [(url: URL, stale: TimeInterval)]
    let timing: ClaudeLockTiming
    let now: @Sendable () -> Date

    /// `configHome` is `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    init(configHome: URL, configURL: URL, timing: ClaudeLockTiming, now: @escaping @Sendable () -> Date) {
        locks = [
            (configHome.appending(path: ".oauth_refresh.lock"), timing.refreshStale),
            // The config home's real path plus ".lock": `~/.claude.lock` by default.
            (URL(fileURLWithPath: configHome.resolvingSymlinksInPath().path + ".lock"), timing.refreshStale),
            // Claude Code locks the config's real path.
            (URL(fileURLWithPath: configURL.resolvingSymlinksInPath().path + ".lock"), timing.configStale),
        ]
        self.timing = timing
        self.now = now
    }

    /// Every lock, or nil once `budget` has passed (anything taken is released).
    func acquire() async -> HeldLocks? {
        let deadline = ContinuousClock.now + timing.budget
        var taken: [URL] = []
        for (url, stale) in locks {
            while !take(url, stale: stale) {
                guard ContinuousClock.now + timing.poll <= deadline else {
                    HeldLocks.remove(taken)
                    return nil
                }
                try? await Task.sleep(for: timing.poll)
            }
            taken.append(url)
        }
        return HeldLocks(taken)
    }

    private func take(_ url: URL, stale: TimeInterval) -> Bool {
        if mkdir(url.path, 0o700) == 0 { return true }
        if errno == ENOENT {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return mkdir(url.path, 0o700) == 0
        }
        guard errno == EEXIST,
              let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now().timeIntervalSince(modified) > stale else { return false }
        rmdir(url.path)
        return mkdir(url.path, 0o700) == 0
    }
}

/// Held lock directories, touched every 3 s so Claude Code never sees them as stale.
final class HeldLocks: Sendable {
    let urls: [URL]
    private let heartbeat: Task<Void, Never>

    init(_ urls: [URL]) {
        self.urls = urls
        heartbeat = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                for url in urls { utimes(url.path, nil) }
            }
        }
    }

    func release() {
        heartbeat.cancel()
        Self.remove(urls)
    }

    static func remove(_ urls: [URL]) {
        for url in urls.reversed() { rmdir(url.path) }
    }
}
