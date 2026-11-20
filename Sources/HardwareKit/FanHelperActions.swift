import Foundation
import OneMacUI

/// Installing, removing and checking the root helper from the fan card.
extension FanController {
    public func refreshHelperStatus() {
        queue.async { [weak self] in
            let status = FanHelper.status()
            DispatchQueue.main.async { self?.helperStatus = status }
        }
    }

    public func installHelper() {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = FanHelper.install()
            let status = FanHelper.status()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.helperStatus = status
                self.message = error
            }
        }
    }

    /// Returns the fans to System, then removes the helper and its sudoers rule (one password prompt).
    public func removeHelper() {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        queue.async { [weak self] in
            // Fans first: once the helper is gone nothing could hand them back.
            let restoreError = FanHelper.invoke(["auto-all"])
            let fans = FanInfo.readAll()
            // The password prompt waits off the fan queue, which a quit or sleep must not find blocked.
            DispatchQueue.global(qos: .userInitiated).async {
                let pinned = fans.contains(where: \.isManual)
                let error = pinned
                    ? tr("Couldn't return the fans to System, so the helper was kept: \(restoreError ?? "")",
                         "Chưa trả được quạt về Hệ thống nên giữ lại helper: \(restoreError ?? "")")
                    : FanHelper.uninstall()
                let status = FanHelper.status()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    self.helperStatus = status
                    self.message = error
                    if !pinned { self.finishRestore() }
                }
            }
        }
    }
}
