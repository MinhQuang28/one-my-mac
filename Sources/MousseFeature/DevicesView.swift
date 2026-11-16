import SwiftUI
import OneMacUI

/// Devices tab: per-mouse scroll profiles. Lists the connected mice plus any saved profile whose
/// mouse is currently unplugged; turning "Custom settings" on seeds a profile from the global
/// Scroll settings, turning it off deletes the profile (the mouse falls back to the global ones).
struct DevicesView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var tracker = DeviceTracker.shared
    @State private var expanded: Set<String> = []

    /// Connected mice first, then profiles for mice that are not connected right now.
    private var rows: [HIDDeviceInfo] {
        let connectedKeys = Set(tracker.connected.map(\.key))
        let offline = store.config.deviceProfiles
            .filter { !connectedKeys.contains($0.id) }
            .map { HIDDeviceInfo(key: $0.id, name: $0.name) }
        return tracker.connected + offline
    }

    var body: some View {
        SettingsPage(pane: .mouseDevices) {
            // Re-read every 2 s so the warning clears once the grant lands (no relaunch needed).
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                if !InputMonitoringPermission.isTrusted {
                    NoticeRow(tr("Per-device settings need Input Monitoring to tell your mice apart. Until then every mouse uses the Scroll page.",
                                 "Cài riêng từng chuột cần quyền Giám sát đầu vào để phân biệt các chuột. Khi chưa cấp, mọi chuột dùng trang Cuộn."),
                              actionTitle: tr("Grant…", "Cấp quyền…")) {
                        if !InputMonitoringPermission.request() { InputMonitoringPermission.openSettings() }
                    }
                }
            }
            if rows.isEmpty {
                ContentUnavailableView(tr("No mouse detected", "Không thấy chuột nào"), systemImage: "computermouse")
                    .frame(maxWidth: .infinity).padding(.vertical, Gap.lg)
            }
            ForEach(rows) { device in
                deviceSection(device)
            }
            Text(tr("A mouse without its own settings uses the Scroll page. Identical mice (same model) share one profile. Right after switching mice, the first scroll may still use the previous mouse's settings.",
                    "Chuột không có cài đặt riêng sẽ dùng trang Cuộn. Chuột cùng model dùng chung một cấu hình. Ngay sau khi đổi chuột, lần cuộn đầu có thể vẫn theo cài đặt của chuột trước."))
                .font(.system(size: FS.label)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, Gap.xs)
        }
        .onAppear { tracker.setTabOpen(true) } // lists connected mice even without a profile
        .onDisappear { tracker.setTabOpen(false) }
    }

    @ViewBuilder
    private func deviceSection(_ device: HIDDeviceInfo) -> some View {
        let connected = tracker.connected.contains { $0.key == device.key }
        let hasProfile = store.config.deviceProfiles.contains { $0.id == device.key }
        let isOpen = expanded.contains(device.key)
        SettingsSection {
            SettingsRow(device.name,
                        detail: (connected ? tr("Connected", "Đang kết nối") : tr("Not connected", "Chưa kết nối"))
                            + " · \(device.key)",
                        icon: "computermouse") {
                Text(tr("Own settings", "Cài riêng")).font(.system(size: FS.label)).foregroundStyle(.secondary)
                SettingsSwitch(isOn: Binding(get: { hasProfile }, set: { on in setCustom(on, for: device) }))
            }
            if hasProfile {
                Button {
                    if isOpen { expanded.remove(device.key) } else { expanded.insert(device.key) }
                } label: {
                    HStack {
                        Text(isOpen ? tr("Hide this mouse's settings", "Ẩn cài đặt của chuột này")
                                    : tr("Edit this mouse's settings", "Sửa cài đặt của chuột này"))
                            .font(.system(size: FS.body, weight: .medium))
                        Spacer()
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: FS.label, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        if hasProfile, isOpen {
            VStack(alignment: .leading, spacing: Gap.lg) {
                ScrollSettingsEditor(settings: profileSettings(device.key))
            }
            .padding(.leading, Gap.lg)
        }
    }

    /// Binding by profile ID, not array index: deleting the profile (its toggle sits right above)
    /// would leave an index binding pointing past the end while SwiftUI tears the editor down.
    private func profileSettings(_ key: String) -> Binding<ScrollDeviceSettings> {
        Binding(
            get: { store.config.deviceProfiles.first { $0.id == key }?.settings ?? store.config.scrollSettings },
            set: { newValue in
                guard let i = store.config.deviceProfiles.firstIndex(where: { $0.id == key }) else { return }
                store.config.deviceProfiles[i].settings = newValue
            })
    }

    private func setCustom(_ on: Bool, for device: HIDDeviceInfo) {
        if on {
            guard !store.config.deviceProfiles.contains(where: { $0.id == device.key }) else { return }
            store.config.deviceProfiles.append(
                DeviceProfile(id: device.key, name: device.name, settings: store.config.scrollSettings))
            expanded.insert(device.key)
        } else {
            store.config.deviceProfiles.removeAll { $0.id == device.key }
            expanded.remove(device.key)
        }
    }
}
