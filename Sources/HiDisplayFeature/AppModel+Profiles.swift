import AppKit
import Foundation
import HiDisplayKit
import OneMacUI
import UniformTypeIdentifiers

/// Saved per-display settings: listing, forgetting, export, import and reset.
///
/// `ProfileStore` has had all of these since the beginning; nothing in the app called them, so a
/// profile saved under a port-based key that no longer exists stayed in the file forever.
extension AppModel {

    /// Refreshes everything derived from the profile file: the list Settings shows and the cache
    /// the coordinator reads saved brightness from.
    func reloadSavedProfiles() async {
        let all = await profiles.allProfiles()
        savedProfiles = all
        // Tolerant of a repeated key for the same reason the diagnostics export is: a hand-edited
        // or imported file must not be able to trap the app at launch.
        savedBrightness = Dictionary(
            all.map { ($0.displayKey, $0.brightness) }, uniquingKeysWith: { first, _ in first })
    }

    /// Saved profiles for displays that are not attached right now.
    var disconnectedProfiles: [DisplayProfile] {
        let live = Set(displays.map(\.id))
        return savedProfiles.filter { !live.contains($0.displayKey) }
    }

    /// Drops everything saved for one display key. A connected display starts over from defaults:
    /// its identity pin goes too, and it is probed again under whatever key it then resolves to.
    func forgetProfile(key: String) {
        Task {
            await profiles.resetProfile(key: key)
            await applyProfileStoreChange()
            profileError = nil
            profileMessage = tr("Forgot the saved settings for that display.",
                                "Đã quên thiết lập đã lưu của màn hình đó.")
        }
    }

    func resetAllProfiles() {
        Task {
            await profiles.resetAll()
            await applyProfileStoreChange()
            profileError = nil
            profileMessage = tr("All saved display settings were reset.",
                                "Đã đặt lại mọi thiết lập màn hình đã lưu.")
        }
    }

    func exportProfiles() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OneMac-display-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await profiles.exportData().write(to: url, options: .atomic)
                profileError = nil
                profileMessage = tr("Exported to \(url.lastPathComponent).",
                                    "Đã xuất ra \(url.lastPathComponent).")
            } catch {
                profileMessage = nil
                profileError = tr("Could not export: \(error.localizedDescription)",
                                  "Không xuất được: \(error.localizedDescription)")
            }
        }
    }

    /// Replaces the saved settings with a previously exported file.
    ///
    /// The file is validated by the store's own decoder — schema version and all — before anything
    /// is replaced, so an unrelated JSON file is refused rather than wiping the current settings.
    func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 4 * 1_048_576 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                try await profiles.importData(data)
                await applyProfileStoreChange()
                profileError = nil
                profileMessage = tr("Imported \(url.lastPathComponent).",
                                    "Đã nhập \(url.lastPathComponent).")
            } catch {
                profileMessage = nil
                profileError = tr("Could not import: \(error)", "Không nhập được: \(error)")
            }
        }
    }

    /// Re-reads the store and re-probes, after a change that may have altered saved brightness,
    /// controller overrides or identity pins for connected displays.
    private func applyProfileStoreChange() async {
        await reloadSavedProfiles()
        discovery.setUserAssignments(await profiles.userAssignments())
        await handleSettled(discovery.displays)
    }
}
