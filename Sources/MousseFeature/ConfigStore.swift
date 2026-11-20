import Foundation
import OneMacUI
import Combine

/// Why the config on disk and the config in memory may disagree. Shown in Settings and the menu
/// so a user whose changes are silently not persisting finds out before the next relaunch.
enum ConfigPersistenceIssue: Equatable, Sendable {
    case loadFailed(String)
    case saveFailed(String)
    case corruptConfigRecovered(backupPath: String?)
    /// The file was readable but some entries (button mappings, device profiles) were not.
    case entriesDropped(backupPath: String?)

    var message: String {
        switch self {
        case let .loadFailed(reason):
            return tr("Settings could not be read (\(reason)). Defaults are in use; the file on disk is untouched until you retry.",
                      "Không đọc được cài đặt (\(reason)). Đang dùng mặc định; tệp trên đĩa được giữ nguyên cho tới khi bạn thử lại.")
        case let .saveFailed(reason):
            return tr("Settings could not be saved (\(reason)).", "Không lưu được cài đặt (\(reason)).")
        case let .corruptConfigRecovered(path?):
            return tr("Settings were unreadable and have been reset. The old file was backed up to \(path).",
                      "Tệp cài đặt bị hỏng và đã được đặt lại. Tệp cũ được sao lưu tại \(path).")
        case .corruptConfigRecovered(nil):
            return tr("Settings were unreadable and could not be backed up. Defaults are in use; the file on disk is untouched until you retry.",
                      "Tệp cài đặt bị hỏng và không sao lưu được. Đang dùng mặc định; tệp trên đĩa được giữ nguyên cho tới khi bạn thử lại.")
        case let .entriesDropped(path?):
            return tr("Some saved settings could not be read and were left out. The original file was backed up to \(path).",
                      "Một số cài đặt đã lưu không đọc được và đã bị bỏ qua. Tệp gốc được sao lưu tại \(path).")
        case .entriesDropped(nil):
            return tr("Some saved settings could not be read and the file could not be backed up. Changes are not saved until you choose to overwrite it.",
                      "Một số cài đặt đã lưu không đọc được và không sao lưu được tệp. Thay đổi chưa được lưu cho tới khi bạn chọn ghi đè.")
        }
    }
}

/// Loads/saves `AppConfig` as JSON in Application Support and pushes changes to the engine.
/// `@MainActor` so SwiftUI can bind to it directly.
@MainActor
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet {
            // `didSet` fires on every assignment, including one that changes nothing — and SwiftUI
            // bindings write identical values constantly (a slider re-asserting its current step,
            // MenuBarExtra re-asserting its insertion state). Without this guard each of those
            // costs a disk write plus a full engine reload, and any binding whose write is itself
            // triggered by the resulting republish spins into a feedback loop.
            guard config != oldValue else { return }
            // Engine first and unconditionally — this is the change the user feels. Only the disk
            // write is deferred: dragging one slider walks ~30 distinct values, and each atomic
            // write (encode, temp file, rename) is main-thread I/O nobody needs mid-drag.
            EventTapEngine.shared.reload(config)
            scheduleSave()
        }
    }

    @Published private(set) var persistenceIssue: ConfigPersistenceIssue?
    /// True while `save()` refuses to touch the file (see `protectsUnreadableConfig`). The UI must
    /// keep the issue visible then — dismissing it would hide that every change is being dropped.
    @Published private(set) var saveIsBlocked = false

    private let fileURL: URL

    /// Non-nil exactly while a change is written-pending — `flushPendingSave()` keys off that.
    private var saveTask: Task<Void, Never>?
    /// Never overwrite the only copy of a config that could not be read or backed up — that would
    /// destroy settings a future build might have decoded. `retrySave()` is the user's explicit
    /// consent to replace it with the current in-memory config.
    private var protectsUnreadableConfig = false {
        didSet { saveIsBlocked = protectsUnreadableConfig }
    }

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mousse", isDirectory: true)
        var initialIssue: ConfigPersistenceIssue?
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            initialIssue = .saveFailed(error.localizedDescription)
        }
        fileURL = dir.appendingPathComponent("config.json")

        // One-time migration: the app was called SilkMouse (and QmouseFix before that) — adopt
        // the newest prior config so a rename doesn't silently reset anyone's settings.
        // (Copy, not move: harmless leftover.)
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let legacy = ["SilkMouse/config.json", "QmouseFix/config.json"]
               .map({ support.appendingPathComponent($0) })
               .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            try? FileManager.default.copyItem(at: legacy, to: fileURL)
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                do {
                    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
                    config = decoded
                    // Tolerant decoding drops what it cannot read (an action from a newer build, a
                    // non-object file) and the next save would erase it for good: keep a copy.
                    if AppConfig.decodingLosesEntries(data, decoded: decoded) {
                        let backupPath = Self.backUp(fileURL)
                        if backupPath == nil { protectsUnreadableConfig = true }
                        initialIssue = .entriesDropped(backupPath: backupPath)
                        NSLog("Mousse: config had unreadable entries; backup: %@", backupPath ?? "failed")
                    }
                } catch {
                    // Undecodable: keep a copy before defaults replace it on the next save.
                    let backupPath = Self.backUp(fileURL)
                    if backupPath == nil { protectsUnreadableConfig = true }
                    config = AppConfig()
                    initialIssue = .corruptConfigRecovered(backupPath: backupPath)
                    NSLog("Mousse: config could not be decoded; defaults loaded, backup: %@",
                          backupPath ?? "failed")
                }
            } catch {
                config = AppConfig()
                protectsUnreadableConfig = true
                initialIssue = .loadFailed(error.localizedDescription)
                NSLog("Mousse: config could not be read: %@", error.localizedDescription)
            }
        } else {
            config = AppConfig()
        }
        persistenceIssue = initialIssue
        saveIsBlocked = protectsUnreadableConfig // `didSet` doesn't fire during init
    }

    /// Coalesce a burst of changes into a single write, half a second after it settles.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.save()
        }
    }

    /// Write a still-pending change out now. Called on quit: a setting the user changed in the last
    /// half second must not die with the process.
    func flushPendingSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// User-initiated: overwrite whatever is on disk with the in-memory config, even one that is
    /// protected because it could not be read.
    func retrySave() {
        saveTask?.cancel()
        saveTask = nil
        save(force: true)
    }

    /// No-op while saving is blocked: the only ways out are Retry (overwrite) or fixing the file.
    func dismissPersistenceIssue() {
        guard !protectsUnreadableConfig else { return }
        persistenceIssue = nil
    }

    private func save(force: Bool = false) {
        guard force || !protectsUnreadableConfig else { return }
        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: fileURL, options: .atomic)
            protectsUnreadableConfig = false
            persistenceIssue = nil // a successful write resolves every kind of issue
        } catch {
            persistenceIssue = .saveFailed(error.localizedDescription)
            NSLog("Mousse: config save failed: %@", error.localizedDescription)
        }
    }

    /// Copies the config aside as `config-corrupt-…`; nil when the copy failed.
    private static func backUp(_ url: URL) -> String? {
        let backupURL = corruptBackupURL(for: url)
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            return backupURL.path
        } catch {
            return nil
        }
    }

    /// Sibling of `url` named `config-corrupt-<ISO timestamp>.json` (colons replaced — APFS accepts
    /// them but Finder shows them as slashes).
    static func corruptBackupURL(for url: URL, at date: Date = Date()) -> URL {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return url.deletingLastPathComponent()
            .appendingPathComponent("config-corrupt-\(stamp).json")
    }
}
