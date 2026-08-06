import Foundation

/// Append-only JSONL of observed usage, written only when a value actually changes.
///
/// Two jobs. First, it settles the open question of whether ClawBar's own polls anchor a
/// 5-hour window — watch whether `r5` advances during a stretch of pure idle heartbeat
/// with no Claude Code use. Second, it gives a record to diagnose against when the
/// undocumented headers inevitably change shape.
///
/// Contains no token and no message content.
final class UsageLog {
    private let url: URL
    private let queue = DispatchQueue(label: "com.victorrodrigues.ClawBar.usagelog", qos: .background)
    private var lastPayload: String?
    private static let maxBytes = 5 * 1024 * 1024

    static var directory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ClawBar")
    }

    init?() {
        let dir = Self.directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        url = dir.appending(path: "usage-log.jsonl")
    }

    func record(_ snapshot: Snapshot) {
        func pair(_ w: UsageWindow?) -> (Double, Int)? {
            guard let w else { return nil }
            return (w.utilization, Int(w.resetsAt.timeIntervalSince1970))
        }
        var fields: [String] = ["\"t\":\(Int(snapshot.fetchedAt.timeIntervalSince1970))"]
        if let s = pair(snapshot.session) { fields.append("\"u5\":\(s.0),\"r5\":\(s.1)") }
        if let w = pair(snapshot.weekly)  { fields.append("\"u7\":\(w.0),\"r7\":\(w.1)") }
        if let o = pair(snapshot.overage) { fields.append("\"uo\":\(o.0),\"ro\":\(o.1)") }
        fields.append("\"claim\":\"\(snapshot.representative)\"")

        // Everything except the timestamp, so an unchanged reading writes nothing.
        let payload = fields.dropFirst().joined(separator: ",")
        guard payload != lastPayload else { return }
        lastPayload = payload

        let line = "{" + fields.joined(separator: ",") + "}\n"
        queue.async { [url] in
            Self.rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > maxBytes else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
