@testable import ClipboardKit
import XCTest

final class ClipboardStoreTests: XCTestCase {
    func testNewestFirstAndBlankOrHugeTextIsIgnored() {
        var store = ClipboardStore()
        XCTAssertTrue(store.record("one"))
        XCTAssertTrue(store.record("two"))
        XCTAssertFalse(store.record("  \n\t "))
        XCTAssertFalse(store.record(String(repeating: "x", count: ClipboardStore.maxTextBytes + 1)))
        XCTAssertEqual(store.items.map(\.text), ["two", "one"])
    }

    func testCopyingTheSameTextAgainMovesItToTheTopAndKeepsItsPin() {
        var store = ClipboardStore()
        store.record("one")
        store.record("two")
        store.togglePin(store.items[1].id)
        store.record("one")
        XCTAssertEqual(store.items.map(\.text), ["one", "two"])
        XCTAssertTrue(store.items[0].isPinned)
    }

    func testLimitDropsTheOldestUnpinnedButNeverAPinnedItem() {
        var store = ClipboardStore()
        store.record("keep")
        store.togglePin(store.items[0].id)
        for index in 0..<(ClipboardStore.limit + 5) { store.record("item \(index)") }
        XCTAssertEqual(store.items.count, ClipboardStore.limit + 1)
        XCTAssertTrue(store.items.contains { $0.text == "keep" })
        XCTAssertFalse(store.items.contains { $0.text == "item 4" })
        XCTAssertTrue(store.items.contains { $0.text == "item 5" })
    }

    func testSearchIgnoresCaseAndAccentsAndListsPinnedFirst() {
        var store = ClipboardStore()
        store.record("Tiếng Việt")
        store.record("hello")
        store.record("HELLO world")
        store.togglePin(store.items[1].id) // "hello"
        XCTAssertEqual(store.matching("tieng viet").map(\.text), ["Tiếng Việt"])
        XCTAssertEqual(store.matching("hello").map(\.text), ["hello", "HELLO world"])
        XCTAssertEqual(store.matching("").first?.text, "hello")
    }

    func testClearKeepsPinnedAndRemoveDeletesOne() {
        var store = ClipboardStore()
        store.record("a")
        store.record("b")
        store.togglePin(store.items[0].id) // "b"
        store.clearUnpinned()
        XCTAssertEqual(store.items.map(\.text), ["b"])
        store.remove(store.items[0].id)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testClassifiesLinksAndEmailsAndLeavesSentencesAsText() {
        XCTAssertEqual(ClipboardKind.classify("https://example.com/a?b=1"), .link)
        XCTAssertEqual(ClipboardKind.classify(" 1910d2-30.myshopify.com\n"), .link)
        XCTAssertEqual(ClipboardKind.classify("help@example.co"), .email)
        XCTAssertEqual(ClipboardKind.classify("watermark."), .text)
        XCTAssertEqual(ClipboardKind.classify("see https://example.com now"), .text)
        XCTAssertEqual(ClipboardKind.classify("v1.2"), .text)
    }

    func testFilterByKindAndSearchByTitle() {
        var store = ClipboardStore()
        store.record("plain words")
        store.record("https://example.com")
        store.record(ClipboardItem(kind: .image, text: "", pixelWidth: 2156, pixelHeight: 1942, contentHash: "abc"))
        store.record(ClipboardItem(kind: .file, text: "/tmp/report.pdf\n/tmp/b.txt"))
        XCTAssertEqual(store.matching("", kind: .link).map(\.text), ["https://example.com"])
        XCTAssertEqual(store.matching("", kind: .image).map(\.title), ["Image (2156×1942)"])
        XCTAssertEqual(store.matching("report").map(\.title), ["report.pdf +1"])
        XCTAssertEqual(store.matching("2156").count, 1)
    }

    func testTheSameImageOrFilesAgainIsNotADuplicateAndTouchMovesToTop() {
        var store = ClipboardStore()
        store.record(ClipboardItem(kind: .image, text: "", contentHash: "abc"))
        store.record("text")
        store.record(ClipboardItem(kind: .image, text: "", contentHash: "abc"))
        XCTAssertEqual(store.items.map(\.kind), [.image, .text])
        store.touch(store.items[1].id)
        XCTAssertEqual(store.items.map(\.kind), [.text, .image])
    }

    func testReadsAHistoryWrittenBeforeKindsExisted() throws {
        let legacy = #"{"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"https://example.com","copiedAt":0,"isPinned":true}]}"#
        let store = try JSONDecoder().decode(ClipboardStore.self, from: Data(legacy.utf8))
        XCTAssertEqual(store.items.first?.kind, .link)
        XCTAssertEqual(store.items.first?.isPinned, true)
    }

    func testSurvivesARoundTripThroughJSON() throws {
        var store = ClipboardStore()
        store.record("a", sourceApp: "Safari")
        let decoded = try JSONDecoder().decode(ClipboardStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(decoded, store)
    }
}

final class ClipboardShortcutTests: XCTestCase {
    func testReadsARecordedShortcutAndTheNamesOlderVersionsStored() {
        XCTAssertEqual(ClipboardShortcutDefaults.shortcut(stored: nil), ClipboardShortcutDefaults.standard)
        XCTAssertEqual(ClipboardShortcutDefaults.shortcut(stored: "commandShiftV"), ClipboardShortcutDefaults.standard)
        XCTAssertEqual(ClipboardShortcutDefaults.shortcut(stored: "optionCommandV").keyCaps, ["⌥", "⌘", "V"])
        XCTAssertEqual(ClipboardShortcutDefaults.shortcut(stored: "8:4352").stored, "8:4352")
        XCTAssertEqual(ClipboardShortcutDefaults.shortcut(stored: "garbage"), ClipboardShortcutDefaults.standard)
    }
}
