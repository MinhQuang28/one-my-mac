import HardwareKit
import HiDisplayFeature
import OneMacUI
import ServiceManagement
import SwiftUI
import WindowKit

/// The Utilities tab: keep-awake, launch at login, brightness keys and display recovery.
struct UtilityCards: View {
    @StateObject private var login = LoginItemState()

    var body: some View {
        VStack(spacing: Gap.sm + 2) {
            KeepAwakeCard()
            WindowSnapCard()
            Card {
                CardHeader(icon: "power", tint: .green, title: tr("Launch at login", "Khởi động cùng macOS"),
                           subtitle: login.detail) {
                    CompactToggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                }
            }
            Card {
                CardHeader(icon: "sun.max.fill", tint: .yellow, title: tr("Brightness keys F1/F2", "Phím độ sáng F1/F2"),
                           subtitle: tr("Dim external displays with the Mac's own keys",
                                        "Chỉnh độ sáng màn ngoài bằng phím của Mac")) {
                    Button(tr("Open…", "Mở…")) { Navigator.shared.open(.brightnessKeys) }.controlSize(.small)
                }
            }
            Card {
                CardHeader(icon: "lifepreserver", tint: .red, title: tr("Rescue a dark screen", "Cứu màn hình tối"),
                           subtitle: tr("Clears all software dimming on every display",
                                        "Xoá mọi làm tối bằng phần mềm trên tất cả màn hình")) {
                    Button("Reset") { HiDisplayModule.resetDimming() }.controlSize(.small)
                }
            }
        }
        .onAppear { login.refresh() }
    }
}

/// Launch-at-login through SMAppService; re-read on appear because the user can change it in System Settings.
@MainActor
final class LoginItemState: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var detail = LoginItemState.idleDetail

    private static var idleDetail: String { tr("Start OneMac when you log in", "Tự chạy OneMac khi đăng nhập") }

    func refresh() {
        let status = SMAppService.mainApp.status
        isOn = status == .enabled
        detail = status == .requiresApproval
            ? tr("Waiting for approval in System Settings › Login Items",
                 "Chờ bật trong Cài đặt hệ thống › Mục đăng nhập")
            : Self.idleDetail
    }

    func set(_ on: Bool) {
        var failure: String?
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = tr("Could not change it: \(error.localizedDescription)",
                         "Không đổi được: \(error.localizedDescription)")
        }
        refresh()
        if let failure { detail = failure }
    }
}
