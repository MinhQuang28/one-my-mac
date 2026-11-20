import CoreGraphics
import Foundation
import HiDisplayKit
import OneMacUI

/// HiDPI override install and undo. Split from `AppModel.swift` by responsibility; every privileged
/// step goes through `PrivilegedInstaller`.
extension AppModel {

    enum InstallOutcome {
        case installed(recoveryPackage: URL, requiresLogout: Bool)
        case cancelled
        case failed(String)
    }

    enum UndoOutcome {
        /// `restoredPrevious` is false when the undo deleted a file that had nothing before it.
        case undone(restoredPrevious: Bool)
        case cancelled
        case failed(String)
    }

    /// The policy the app installs with. Merge, because that is what the UI promises: the tab is
    /// titled "Resolutions to add", and the confirmation says existing entries are kept. `.replace`
    /// here would make both of those false — it briefly did, and destroyed a 242-entry override
    /// written by another tool. Removing modes is a different feature (undoing an install), not a
    /// side effect of adding some. Export uses the same policy so both routes stage the same file.
    static let installPolicy = OverrideInstaller.ExistingContentPolicy.merge

    static var overrideRoot: URL { URL(fileURLWithPath: OverridePaths.systemOverrideRoot) }

    /// The app's own copies of the recovery packages it has written.
    private static var installedOverrides: InstalledOverrideStore {
        InstalledOverrideStore(directory: InstalledOverrideStore.defaultDirectory())
    }

    /// Works out what installing would change, writing nothing.
    ///
    /// Separate from `performInstall` so the UI can put the whole plan — the destination, the file
    /// being replaced, what is discarded, the undo command — in front of the user *before* asking for
    /// a password. A privileged write the user has not seen described is not a reviewable one.
    func planInstall(
        _ generated: GeneratedOverride, for display: DisplayDevice
    ) throws -> InstallationPlan {
        let installer = OverrideInstaller(root: Self.overrideRoot, appVersion: Self.version)
        return try installer.plan(generated: generated, display: display, policy: Self.installPolicy)
    }

    /// Backs up, installs and verifies a plan the user has already approved, prompting for
    /// authorization once.
    ///
    /// The recovery package is created **before** the privileged write, not after: if the write goes
    /// wrong, the way back has to already exist. `async` because the password prompt can stay open
    /// for as long as the user likes, and the main actor must not wait on it.
    /// - Note: the bytes written come from `plan.payload`, not from any `GeneratedOverride` the caller
    ///   still has to hand. Those two differ whenever an override is already installed, and writing
    ///   the caller's copy is what silently discarded another tool's modes.
    func performInstall(_ plan: InstallationPlan) async -> InstallOutcome {
        guard plan.isInstallable else {
            return .failed(plan.validation.errors.map(\.message).joined(separator: "\n"))
        }
        do {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let package = try RecoveryPackageBuilder.create(manifest: plan.manifest, in: downloads)

            // Copy the file being replaced into the package while we can still read it. This throws
            // if the file no longer matches the plan — the plan (and its merged payload) is then
            // stale, and installing it would both lose the newer content and produce a recovery
            // package whose own restore script rejects the backup.
            let installer = OverrideInstaller(root: plan.root, appVersion: Self.version)
            do {
                try installer.stageBackups(for: plan.manifest, into: package.backupDirectory)
            } catch InstallerError.manifestMismatch {
                try? FileManager.default.removeItem(at: package.directory)
                return .failed(Self.planIsStaleMessage)
            }

            do {
                try await PrivilegedInstaller.install(plan: plan, payload: plan.payload)
            } catch PrivilegedInstaller.InstallError.cancelled {
                // Cancelling happens before anything runs as root, so nothing on the system changed.
                // Leaving a recovery package behind would contradict the message the UI then shows —
                // and a recovery folder for a change that never happened is only confusing later.
                try? FileManager.default.removeItem(at: package.directory)
                return .cancelled
            } catch {
                // Any other failure: keep the package only if the override file actually changed.
                // A refused or failed script leaves the file exactly as planned-against, and a
                // recovery folder describing an install that did not happen is an orphan.
                if Self.targetIsUntouched(by: plan) {
                    try? FileManager.default.removeItem(at: package.directory)
                }
                return .failed(error.localizedDescription)
            }

            // The app's own copy, so the install can be undone from here after the Downloads
            // folder has been tidied away. Failing to keep it does not undo the install.
            do {
                try Self.installedOverrides.record(package)
            } catch {
                Log.hidpiInstaller.error(
                    "could not keep a copy of the recovery package: \(String(describing: error), privacy: .public)")
            }
            return .installed(recoveryPackage: package.directory, requiresLogout: plan.requiresLogout)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static var planIsStaleMessage: String {
        tr("""
            The override file changed after this install was planned. Nothing was written. \
            Try again to re-read the file and see an updated plan.
            """, """
            Tệp override đã thay đổi sau khi lập kế hoạch cài đặt. Chưa ghi gì cả. \
            Thử lại để đọc lại tệp và xem kế hoạch mới.
            """)
    }

    /// Whether the plan's destination still holds exactly what it held when the plan was made.
    private static func targetIsUntouched(by plan: InstallationPlan) -> Bool {
        guard let action = plan.actions.last(where: { $0.kind != .createDirectory }) else { return true }
        return SHA256Hash.hex(ofFileAt: URL(fileURLWithPath: action.absolutePath)) == action.sha256Before
    }

    // MARK: - Undo

    /// The undo this app can offer for a display's installed override, if any.
    ///
    /// `nil` when no override is installed, when the installed file is not one this app wrote, or
    /// when the copy of what it replaced is gone — the app only undoes what it can vouch for.
    func availableUndo(for display: DisplayDevice) -> OverrideUndo? {
        Self.installedOverrides.undo(
            vendorID: display.identity.vendorID, productID: display.identity.productID,
            root: Self.overrideRoot)
    }

    /// Undoes the last install for a display: puts the previous file back, or removes the override
    /// when there was none before. Prompts for authorization once.
    func performUndo(_ undo: OverrideUndo) async -> UndoOutcome {
        // Checked again here, not only when the button appeared: the confirmation can stay open,
        // and overwriting a file another tool wrote in the meantime is what this refuses to do.
        let root = Self.overrideRoot
        guard let target = try? OverridePaths.resolve(relativePath: undo.relativePath, under: root),
              SHA256Hash.hex(ofFileAt: target) == undo.installedHash
        else {
            return .failed(tr(
                "The override file is no longer the one OneMac installed, so it was left alone.",
                "Tệp override không còn là tệp OneMac đã cài nên được giữ nguyên."))
        }
        do {
            switch undo.kind {
            case .remove:
                try await PrivilegedInstaller.remove(
                    relativePath: undo.relativePath, under: root, installedHash: undo.installedHash)
                return .undone(restoredPrevious: false)
            case .restorePrevious(let data, let sha256):
                try await PrivilegedInstaller.write(
                    data, relativePath: undo.relativePath, under: root, approvedHash: sha256,
                    prompt: tr(
                        "OneMac wants to put back the previous display override in /Library/Displays.",
                        "OneMac muốn đưa override màn hình trước đó trở lại /Library/Displays."))
                return .undone(restoredPrevious: true)
            }
        } catch PrivilegedInstaller.InstallError.cancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Applying without a logout

    /// Whether a just-written override can be applied by reconnecting `display` in software.
    func canReloadOverride(for display: DisplayDevice) -> Bool {
        !display.isBuiltIn && DisplayReconnector.canReconnect(display.cgDisplayID)
    }

    /// Soft-reconnects `display` so macOS loads the override file now, then puts the display back
    /// on the mode it was showing — re-enumeration tends to land on macOS's default instead.
    ///
    /// Returns `nil` on success, or why it could not be done; the caller then falls back to asking
    /// for a replug or a logout, which is no worse than before this existed.
    func reloadOverride(for display: DisplayDevice) async -> String? {
        let before = display.currentMode
        let restored: CGDirectDisplayID
        do {
            restored = try await DisplayReconnector.reconnect(display.cgDisplayID)
        } catch {
            Log.hidpiInstaller.error("soft reconnect failed: \(String(describing: error), privacy: .public)")
            refreshAfterModeChange()
            return "\(error)"
        }
        if let before, DisplayModeService.currentMode(for: restored)?.id != before.id {
            // Only a mode it was already showing, so no keep/revert dialog; a size that no longer
            // exists (an undo removed it) just leaves macOS's own choice in place.
            _ = try? await DisplayModeSwitcher.apply(before, to: restored)
        }
        refreshAfterModeChange()
        return nil
    }

    /// Ends the session so the new override takes effect. Profiles are flushed first — a logout gives
    /// the app no more warning than a restart does — and *awaited*: firing the logout Apple event in
    /// the same breath as an unawaited flush was a race the flush usually lost.
    func endSession(_ kind: PrivilegedInstaller.SessionEnd) {
        Task {
            await profiles.flush()
            sessionEndError = nil
            do { try PrivilegedInstaller.endSession(kind) } catch { sessionEndError = error.localizedDescription }
        }
    }
}
