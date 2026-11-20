import EyeBreakKit
import HardwareKit
import HiDisplayFeature
import MousseFeature
import OneMacUI
import SwiftUI

enum PanelTab: Int, CaseIterable {
    case displays, mouse, hardware, utilities

    var title: String {
        switch self {
        case .displays: return tr("Displays", "Màn hình")
        case .mouse: return tr("Mouse", "Chuột")
        case .hardware: return tr("Hardware", "Phần cứng")
        case .utilities: return tr("Utilities", "Tiện ích")
        }
    }

    var icon: String {
        switch self {
        case .displays: return "display"
        case .mouse: return "computermouse"
        case .hardware: return "bolt.batteryblock"
        case .utilities: return "square.grid.2x2"
        }
    }
}

/// The menu-bar panel: header with live stats, tab bar, tab content, footer.
struct PanelView: View {
    @AppStorage("panel_tab") private var tabRaw = PanelTab.hardware.rawValue
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.openWindow) private var openWindow
    /// The PNG renderer cannot draw inside a ScrollView, so previews lay the content out flat.
    var flatLayout = false
    /// Forces a tab when rendering previews.
    var previewTab: PanelTab?

    private var tab: PanelTab { previewTab ?? PanelTab(rawValue: tabRaw) ?? .hardware }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
                .padding(.horizontal, Gap.md).padding(.top, Gap.md).padding(.bottom, Gap.sm)
            PanelTabBar(selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }))
                .padding(.horizontal, Gap.md).padding(.bottom, Gap.sm)
            Divider().padding(.horizontal, Gap.md)
            if flatLayout {
                content.padding(Gap.md)
                Spacer(minLength: 0)
            } else {
                ScrollView { content.padding(Gap.md) }
            }
            Divider().padding(.horizontal, Gap.md)
            PanelFooter()
                .padding(.horizontal, Gap.md).padding(.vertical, Gap.sm)
        }
        .frame(width: PanelSize.width, height: PanelSize.height)
        .id(language.language) // rebuild every string when the language changes
        .onAppear {
            Navigator.shared.showWindow = { openWindow(id: SettingsWindow.id) }
            HardwareMonitor.shared.setVisible(true)
        }
        .onDisappear { HardwareMonitor.shared.setVisible(false) }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .displays: DisplayCards()
        case .mouse: MouseCards()
        case .hardware:
            VStack(spacing: Gap.sm + 2) {
                BatteryCard()
                ThermalFanCard()
                MenuBarStatsCard()
            }
        case .utilities: UtilityCards()
        }
    }
}

/// App name plus three live chips: battery, CPU temperature, keep-awake.
struct PanelHeader: View {
    @ObservedObject private var monitor = HardwareMonitor.shared
    @ObservedObject private var keepAwake = KeepAwake.shared

    var body: some View {
        HStack(spacing: Gap.sm) {
            Image(systemName: AppInfo.symbol)
                .font(.system(size: FS.subhead, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Rad.sm + 2, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text("OneMac").font(.system(size: FS.subhead, weight: .semibold))
            Spacer()
            if let b = monitor.battery {
                chip(b.isCharging ? "battery.100.bolt" : "battery.75", "\(b.percent)%")
            }
            if let t = monitor.thermal.cpuAverage {
                chip("thermometer.medium", String(format: "%.0f°", t))
            }
            if keepAwake.isActive { chip("cup.and.saucer.fill", tr("Awake", "Thức")) }
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text).monospacedDigit()
        }
        .font(.system(size: FS.label, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Capsule().fill(Color.tileFill))
    }
}

/// Four equal tabs with icon + label.
struct PanelTabBar: View {
    @Binding var selection: PanelTab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: FS.title, weight: .medium))
                        Text(tab.title).font(.system(size: FS.caption, weight: selected ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: Rad.sm + 2, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Rad.md, style: .continuous).fill(Color.tileFill))
    }
}

struct PanelFooter: View {
    var body: some View {
        HStack {
            Button { Navigator.shared.open(.general) } label: {
                Label(tr("Settings", "Cài đặt"), systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("v\(AppInfo.version)").font(.system(size: FS.caption)).foregroundStyle(.tertiary)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label(tr("Quit", "Thoát"), systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.system(size: FS.label, weight: .medium))
    }
}

enum AppInfo {
    static let version = "0.1.0"
    /// Logo glyph: menu bar, panel header and the app icon (tools/make-icon.swift).
    static let symbol = "gauge.with.dots.needle.67percent"
}

/// Menu-bar item: the logo, plus whichever live numbers the user switched on.
struct MenuBarLabel: View {
    @ObservedObject private var usage = SystemUsageMonitor.shared
    @ObservedObject private var monitor = HardwareMonitor.shared
    @ObservedObject private var breaks = EyeBreaks.shared

    var body: some View {
        // System stats first, then the eye-break countdown; either may be off.
        let parts = [usage.menuBarText(temperature: monitor.thermal.cpuAverage), breaks.menuBarStatus]
            .compactMap { $0 }
        if parts.isEmpty {
            Image(systemName: AppInfo.symbol)
        } else {
            HStack(spacing: 4) {
                Image(systemName: AppInfo.symbol)
                Text(parts.joined(separator: " · ")).monospacedDigit()
            }
        }
    }
}
