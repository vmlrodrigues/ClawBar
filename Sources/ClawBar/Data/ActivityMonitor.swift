import Foundation

/// Watches `~/.claude` for evidence that Claude Code is actually in use.
///
/// This is the load-bearing piece of the poll policy. Every poll is an inference
/// request, and an inference request most likely anchors a 5-hour session window — so a
/// naive fixed-interval poller would manufacture the usage the app exists to report.
/// FSEvents costs essentially nothing next to stat-polling a directory tree.
///
/// Blind spot worth knowing: this only sees Claude *Code*. Usage from claude.ai or the
/// desktop app leaves no trace here, which is what the idle heartbeat setting is for.
final class ActivityMonitor {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.victorrodrigues.ClawBar.fsevents", qos: .utility)
    private let lock = NSLock()
    private var storedLastActivity: Date
    private let onActivity: () -> Void

    var lastActivity: Date {
        lock.lock(); defer { lock.unlock() }
        return storedLastActivity
    }

    var idleFor: TimeInterval { Date().timeIntervalSince(lastActivity) }

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        self.storedLastActivity = Self.newestKnownActivity()
        start()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Seed from the filesystem so a fresh launch doesn't wrongly conclude you're idle.
    ///
    /// A directory's mtime only changes when entries are added, removed or renamed —
    /// *not* when a file inside it is written. `projects/` and `history.jsonl` were
    /// observed hours stale during active use for exactly that reason, which made a
    /// fresh launch drop straight to the idle heartbeat. These are the paths that
    /// actually move while Claude Code is running.
    private static func newestKnownActivity() -> Date {
        let claude = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        let candidates = ["sessions", "backups", "shell-snapshots", "tasks",
                          "session-env", "projects", "history.jsonl"]
            .map { claude.appending(path: $0) }

        var newest = Date.distantPast
        for url in candidates {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate {
                newest = max(newest, modified)
            }
        }
        return newest
    }

    private func start() {
        let watched = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        guard FileManager.default.fileExists(atPath: watched.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ActivityMonitor>.fromOpaque(info).takeUnretainedValue().noteActivity()
        }

        // 5s latency coalesces bursts of writes into one callback. Directory-level
        // events only — file-level would fire far more often for no extra signal.
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watched.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func noteActivity() {
        lock.lock()
        storedLastActivity = Date()
        lock.unlock()
        onActivity()
    }
}
