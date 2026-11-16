import CoreGraphics

/// Remembers, per window, the frame it had before OneMac first arranged it, so `restore` can put it back.
///
/// A record also keeps the frame OneMac last placed the window at. When the next action finds the window
/// somewhere else, the user has moved it by hand since, and that new frame becomes the one to restore.
struct WindowRestoreMemory<Key: Hashable> {
    private struct Record {
        var saved: CGRect
        var placed: CGRect?
    }

    private var records: [Key: Record] = [:]
    /// Keys oldest first, so the least recently used window is forgotten when full.
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int = 64) { self.limit = max(1, limit) }

    /// Call before arranging a window, with the frame it has right now.
    mutating func willArrange(_ key: Key, from frame: CGRect) {
        if let record = records[key], let placed = record.placed, Self.matches(placed, frame) {
            touch(key)
            return // still where OneMac left it: keep the older frame to restore to
        }
        records[key] = Record(saved: frame, placed: nil)
        touch(key)
        if order.count > limit { records[order.removeFirst()] = nil }
    }

    /// Call once the window has settled, with the frame it actually ended up at.
    mutating func didArrange(_ key: Key, at frame: CGRect) {
        records[key]?.placed = frame
    }

    func savedFrame(for key: Key) -> CGRect? { records[key]?.saved }

    /// Hands back the frame to restore and forgets the window.
    mutating func takeSavedFrame(for key: Key) -> CGRect? {
        order.removeAll { $0 == key }
        return records.removeValue(forKey: key)?.saved
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static func matches(_ a: CGRect, _ b: CGRect, slack: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= slack && abs(a.minY - b.minY) <= slack
            && abs(a.width - b.width) <= slack && abs(a.height - b.height) <= slack
    }
}
