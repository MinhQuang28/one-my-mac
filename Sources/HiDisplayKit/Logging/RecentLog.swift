import Foundation
import OSLog

/// The display stack's own log lines from this launch, for the support report.
///
/// A customer cannot be asked to run `log stream` while reproducing a fault. The unified log
/// already holds what the app said since it started — which controller each display got, every
/// failed bind and every fallback — so the report copies it out instead.
public enum RecentLog {

    /// Only the categories declared in `Log`, which are bound by its rule: no serial number, EDID
    /// or home path. The subsystem is shared with the rest of the app, whose lines stay out.
    static let categoryPrefixes = ["display.", "ddc.", "brightness.", "platform.", "profile", "recovery"]

    public static func lines(limit: Int = 400) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(
                matching: NSPredicate(format: "subsystem == %@", Log.subsystem))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries
            where categoryPrefixes.contains(where: entry.category.hasPrefix) {
                lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
            }
            return Array(lines.suffix(limit))
        } catch {
            return ["log unavailable: \(error.localizedDescription)"]
        }
    }
}
