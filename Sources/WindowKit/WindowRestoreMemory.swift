import CoreGraphics

/// Remembers, per window, the frame it had before OneMac first arranged it, so `restore` can put it back.
///
/// A record also keeps where OneMac last left the window: the frame it asked for and the frame the app
/// actually gave it (an app may clamp the size, or still be animating when it is sampled). When the next
/// action finds the window at neither, the user has moved it by hand since, and that new frame becomes
/// the one to restore.
struct WindowRestoreMemory<Key: Hashable> {
    private struct Record {
        var saved: CGRect
        var placed: [CGRect] = []
    }

    private var records: [Key: Record] = [:]
    /// Keys oldest first, so the least recently used window is forgotten when full.
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int = 64) { self.limit = max(1, limit) }

    /// Call before arranging a window, with the frame it has right now.
    mutating func willArrange(_ key: Key, from frame: CGRect) {
        if let record = records[key], Self.isWhereLeft(record, frame) {
            touch(key)
            return // still where OneMac left it: keep the older frame to restore to
        }
        records[key] = Record(saved: frame)
        touch(key)
        if order.count > limit { records[order.removeFirst()] = nil }
    }

    /// Call once the window was written, and again when it settled: `target` is the frame asked for,
    /// `frame` the one it actually has.
    mutating func didArrange(_ key: Key, target: CGRect, at frame: CGRect) {
        records[key]?.placed = [target, frame]
    }

    func savedFrame(for key: Key) -> CGRect? { records[key]?.saved }

    /// Hands back the frame to restore and forgets the window. `current` is where the window is now:
    /// if the user dragged it away from where OneMac left it, the saved frame is stale — the window is
    /// already where they want it — so nothing is handed back.
    mutating func takeSavedFrame(for key: Key, current: CGRect) -> CGRect? {
        order.removeAll { $0 == key }
        guard let record = records.removeValue(forKey: key) else { return nil }
        return record.placed.isEmpty || Self.isWhereLeft(record, current) ? record.saved : nil
    }

    private static func isWhereLeft(_ record: Record, _ frame: CGRect) -> Bool {
        record.placed.contains { WindowLayout.matches($0, frame, slack: 3) }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
