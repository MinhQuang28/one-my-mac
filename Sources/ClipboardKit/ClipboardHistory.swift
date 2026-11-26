import AppKit
import Carbon.HIToolbox
import WindowKit

/// Records what is copied on this Mac — text, links, images and files — and pastes an earlier
/// item back on request.
///
/// Off until the user switches it on. macOS posts nothing when the pasteboard changes, so this
/// polls its change counter — one integer read, twice a second, and only while enabled.
@MainActor
public final class ClipboardHistory: ObservableObject {
    public static let shared = ClipboardHistory()
    private static let pollInterval: TimeInterval = 0.5

    private enum Key {
        static let enabled = "clipboard_history_enabled"
        static let shortcut = "clipboard_history_shortcut"
    }

    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            sync()
        }
    }
    @Published public var shortcut: WindowShortcut {
        didSet {
            guard shortcut != oldValue else { return }
            UserDefaults.standard.set(shortcut.stored, forKey: Key.shortcut)
            sync()
        }
    }
    /// While a new shortcut is being recorded the current one is released, so pressing it is
    /// captured by the recorder instead of opening the history.
    var isRecordingShortcut = false {
        didSet { if isRecordingShortcut != oldValue { sync() } }
    }
    /// False when the system refused the shortcut.
    @Published public private(set) var shortcutRegistered = true
    @Published private(set) var store = ClipboardStore()

    public var itemCount: Int { store.items.count }
    public var shortcutKeyCaps: String { shortcut.keyCaps.joined() }
    var usesDefaultShortcut: Bool { shortcut == ClipboardShortcutDefaults.standard }
    /// Pasting into the app in front is a synthetic ⌘V, which needs Accessibility. Without it the
    /// chosen item is still put on the clipboard.
    public var canPasteDirectly: Bool { AXIsProcessTrusted() }

    private let fileURL: URL
    let imagesDirectory: URL
    private let saveQueue = DispatchQueue(label: "com.onemac.clipboard-history", qos: .utility)
    private let thumbnails = NSCache<NSString, NSImage>()
    private let thumbnailQueue = DispatchQueue(label: "com.onemac.clipboard-thumbnails", qos: .userInitiated,
                                               attributes: .concurrent)
    /// Thumbnails being decoded, or that could not be: neither is started a second time.
    private var requestedThumbnails: Set<String> = []
    private lazy var hotkey = ClipboardHotkey { [weak self] in self?.panel.toggle() }
    private lazy var panel = ClipboardPanel(history: self)
    private var timer: Timer?
    private var lastChangeCount = 0
    private var started = false

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        shortcut = ClipboardShortcutDefaults.shortcut(stored: defaults.string(forKey: Key.shortcut))
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OneMac")
        fileURL = folder.appendingPathComponent("clipboard-history.json")
        imagesDirectory = folder.appendingPathComponent("clipboard-images")
        // Decoded pixels, not file sizes: a 1200-pixel preview is several megabytes in memory.
        thumbnails.totalCostLimit = 64 * 1_048_576
    }

    public func start() {
        guard !started else { return }
        started = true
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(ClipboardStore.self, from: data) {
            store = saved
        }
        sync()
    }

    public func stop() {
        started = false
        sync()
    }

    /// Brings the timer and the hot key in line with the switch.
    private func sync() {
        guard started, isEnabled else {
            timer?.invalidate()
            timer = nil
            hotkey.unregister()
            panel.close()
            return
        }
        if isRecordingShortcut {
            hotkey.unregister()
        } else {
            shortcutRegistered = hotkey.register(shortcut)
        }
        guard timer == nil else { return }
        // What is on the clipboard now was copied before the user asked for a history.
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = Self.pollInterval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let front = NSWorkspace.shared.frontmostApplication
        let sourceApp = front?.localizedName, bundleID = front?.bundleIdentifier
        switch ClipboardPasteboard.read(pasteboard) {
        case .text(let text):
            if store.record(text, sourceApp: sourceApp, sourceBundleID: bundleID) { save() }
        case .files(let urls):
            store.record(ClipboardItem(kind: .file, text: urls.map(\.path).joined(separator: "\n"), sourceApp: sourceApp,
                                       sourceBundleID: bundleID))
            save()
        case .image(let data):
            // Converting a large screenshot to PNG takes a moment; keep it off the main thread.
            let directory = imagesDirectory
            saveQueue.async { [weak self] in
                guard let item = ClipboardPasteboard.storeImage(data, in: directory, sourceApp: sourceApp,
                                                                sourceBundleID: bundleID) else { return }
                DispatchQueue.main.async {
                    self?.store.record(item)
                    self?.save()
                }
            }
        case nil:
            break
        }
    }

    // MARK: - Actions

    /// Puts `item` on the clipboard and moves it to the top of the history.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        ClipboardPasteboard.write(item, imagesDirectory: imagesDirectory, to: pasteboard)
        // Our own write is not a new copy; re-reading it would duplicate images.
        lastChangeCount = pasteboard.changeCount
        store.touch(item.id)
        save()
        panel.close()
    }

    /// Copies `item` and, when allowed, pastes it into the app in front.
    func paste(_ item: ClipboardItem) {
        copy(item)
        guard canPasteDirectly else { return }
        // After the panel has given key focus back to the app the user was in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    /// Opens a link in the browser, an e-mail address in the mail app, or shows files in Finder.
    func open(_ item: ClipboardItem) {
        let value = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.kind {
        case .link:
            if let url = URL(string: value.contains("://") ? value : "https://\(value)") { NSWorkspace.shared.open(url) }
        case .email:
            if let url = URL(string: "mailto:\(value)") { NSWorkspace.shared.open(url) }
        case .file:
            NSWorkspace.shared.activateFileViewerSelecting(item.filePaths.map { URL(fileURLWithPath: $0) })
        case .image:
            if let file = item.imageFile { NSWorkspace.shared.open(imagesDirectory.appendingPathComponent(file)) }
        case .text:
            return
        }
        panel.close()
    }

    func togglePin(_ item: ClipboardItem) {
        store.togglePin(item.id)
        save()
    }

    func remove(_ item: ClipboardItem) {
        store.remove(item.id)
        save()
    }

    public func clear() {
        store.clearUnpinned()
        save()
    }

    public func showPanel() { panel.toggle() }

    /// A downscaled picture of an image item. Returns what is cached; otherwise decodes in the
    /// background and publishes a change when it is ready. Decoding a full-screen screenshot takes
    /// a noticeable moment, and doing a list of them on the main thread froze the window.
    func thumbnail(for item: ClipboardItem, maxPixel: Int) -> NSImage? {
        guard let file = item.imageFile else { return nil }
        let key = "\(file)-\(maxPixel)"
        if let cached = thumbnails.object(forKey: key as NSString) { return cached }
        guard requestedThumbnails.insert(key).inserted else { return nil }
        let url = imagesDirectory.appendingPathComponent(file)
        thumbnailQueue.async { [weak self] in
            guard let image = ClipboardPasteboard.thumbnail(of: url, maxPixel: maxPixel) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnails.setObject(image, forKey: key as NSString,
                                          cost: Int(image.size.width * image.size.height) * 4)
                // Allowed again, in case the cache evicts it later.
                self.requestedThumbnails.remove(key)
                self.objectWillChange.send()
            }
        }
        return nil
    }

    #if DEBUG
    /// For the PNG preview renderer: sample copies instead of the user's own history. Never saved.
    func loadPreviewSamples() {
        var samples = ClipboardStore()
        samples.record("Offer or upsell", sourceApp: "Notes", sourceBundleID: "com.apple.Notes")
        samples.record("yanet-order-tracking", sourceApp: "Safari", sourceBundleID: "com.apple.Safari")
        samples.record("1910d2-30.myshopify.com", sourceApp: "Safari", sourceBundleID: "com.apple.Safari")
        samples.record("help@example.com", sourceApp: "Mail", sourceBundleID: "com.apple.mail")
        samples.record(ClipboardItem(kind: .file, text: "/Applications/Safari.app\n/Applications/Notes.app",
                                     sourceApp: "Finder", sourceBundleID: "com.apple.finder"))
        samples.record("Tốc độ mạng và dung lượng trống trên menu bar được lấy mẫu mỗi 2,5 giây.",
                       sourceApp: "Terminal", sourceBundleID: "com.apple.Terminal")
        store = samples
    }
    #endif

    /// Owner-only file, written off the main thread. Copies are rare enough not to need a debounce.
    private func save() {
        let snapshot = store
        let url = fileURL
        let images = imagesDirectory
        saveQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NSLog("OneMac: could not save the clipboard history: \(error.localizedDescription)")
            }
            ClipboardPasteboard.removeOrphanImages(in: images, keeping: Set(snapshot.items.compactMap(\.imageFile)))
        }
    }
}
