import Foundation

/// The history itself: newest first, duplicates folded, unpinned items capped. Pure value logic,
/// so every rule is unit-testable without a pasteboard.
struct ClipboardStore: Codable, Equatable {
    /// How many unpinned items are kept. Pinned ones do not count and are never dropped.
    static let limit = 100
    /// Longer text is not recorded: a pasted log file would bloat the history file and the list.
    static let maxTextBytes = 100_000
    /// How far into each item a search looks. An accent-insensitive search through a hundred
    /// 100 KB copies took most of a second per keystroke; what people search for is near the start.
    static let searchedCharacters = 2_000

    private(set) var items: [ClipboardItem] = []

    /// Adds copied text, classified as text, link or e-mail.
    /// - Returns: false when the text was ignored (blank or too long).
    @discardableResult
    mutating func record(_ text: String, at date: Date = Date(), sourceApp: String? = nil,
                         sourceBundleID: String? = nil) -> Bool {
        guard text.utf8.count <= Self.maxTextBytes,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        record(ClipboardItem(kind: ClipboardKind.classify(text), text: text, copiedAt: date, sourceApp: sourceApp,
                             sourceBundleID: sourceBundleID))
        return true
    }

    /// Adds a copy, or moves an identical earlier one back to the top.
    mutating func record(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.signature == item.signature }) {
            var existing = items.remove(at: index)
            existing.copiedAt = item.copiedAt
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        trim()
    }

    /// Moves an item to the top, as when it has just been pasted.
    mutating func touch(_ id: UUID, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.copiedAt = date
        items.insert(item, at: 0)
    }

    mutating func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        trim()
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Clears the history but keeps what the user pinned.
    mutating func clearUnpinned() {
        items.removeAll { !$0.isPinned }
    }

    /// Pinned items first, then newest first; limited to one kind when asked, and filtered by
    /// `query` ignoring case and accents, so "tieng viet" finds "Tiếng Việt".
    func matching(_ query: String, kind: ClipboardKind? = nil) -> [ClipboardItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let found = items.filter { item in
            guard kind == nil || item.kind == kind else { return false }
            return needle.isEmpty || item.text.prefix(Self.searchedCharacters).range(of: needle, options: options) != nil
                || item.title.range(of: needle, options: options) != nil
        }
        return found.filter(\.isPinned) + found.filter { !$0.isPinned }
    }

    private mutating func trim() {
        var kept = 0
        items.removeAll { item in
            guard !item.isPinned else { return false }
            kept += 1
            return kept > Self.limit
        }
    }
}
