import Foundation
import OneMacUI

/// Observable state of the system charge limit. The system is the source of truth (the user can
/// also change it in System Settings), so the value is re-read whenever the battery card appears.
@MainActor
public final class ChargeLimit: ObservableObject {
    public static let shared = ChargeLimit()
    public static let levels = ChargeLimitClient.levels
    private static let preferredKey = "charge_limit_preferred"

    /// False on desktops, Intel Macs and macOS builds without the PowerUI charge-limit client.
    @Published public private(set) var isSupported = false
    /// Active limit in percent; nil = charge to 100 %.
    @Published public private(set) var limit: Int?
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?

    /// The level the switch turns on: the last one the user picked.
    public private(set) var preferred: Int

    private let queue = DispatchQueue(label: "com.onemac.charge-limit", qos: .userInitiated)
    private let box = ClientBox()

    /// Holds the client for `queue`, which is the only place it is created and used (loading the
    /// framework and the first XPC call can take a moment, so not on the main thread).
    private final class ClientBox: @unchecked Sendable {
        lazy var client = ChargeLimitClient()
    }

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Self.preferredKey)
        preferred = Self.levels.contains(saved) ? saved : 80
    }

    public func refresh() {
        run { client in (client.currentLimit(), true) }
    }

    public func setEnabled(_ on: Bool) {
        if on { setLimit(preferred) } else {
            run { client in
                let ok = client.disable()
                return (client.currentLimit(), ok)
            }
        }
    }

    public func setLimit(_ percent: Int) {
        guard Self.levels.contains(percent) else { return }
        preferred = percent
        UserDefaults.standard.set(percent, forKey: Self.preferredKey)
        run { client in
            let ok = client.setLimit(percent)
            return (client.currentLimit(), ok)
        }
    }

    /// Runs one client call off the main thread and publishes the state the system reports back.
    private func run(_ work: @escaping (ChargeLimitClient) -> (limit: Int?, ok: Bool)) {
        isBusy = true
        queue.async { [box] in
            let result = box.client.map(work)
            DispatchQueue.main.async {
                self.isBusy = false
                self.isSupported = result != nil
                guard let result else { return }
                self.limit = result.limit
                self.message = result.ok ? nil : tr("macOS refused to change the charge limit.",
                                                    "macOS từ chối thay đổi giới hạn sạc.")
            }
        }
    }
}
