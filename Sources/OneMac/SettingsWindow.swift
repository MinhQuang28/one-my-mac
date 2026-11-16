import HardwareKit
import HiDisplayFeature
import MousseFeature
import OneMacUI
import SwiftUI
import WindowKit

/// The full settings window: sidebar of displays, display tools, mouse pages and app settings.
struct SettingsWindow: View {
    static let id = "settings"
    @ObservedObject private var navigator = Navigator.shared
    @ObservedObject private var directory = DisplayDirectory.shared
    @ObservedObject private var language = LanguageSettings.shared

    private static let displayTools: [SettingsPane] = [.hiDPI, .brightnessKeys, .displayDiagnostics]
    private static let mousePages: [SettingsPane] = [.mouseGeneral, .mouseButtons, .mouseScroll, .mouseDevices, .mouseGestures]

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding<SettingsPane?>(get: { navigator.pane },
                                                   set: { if let p = $0 { navigator.pane = p } })) {
                Section(tr("Displays", "Màn hình")) {
                    ForEach(directory.displays) { display in
                        SidebarRow(title: display.name, icon: display.isBuiltIn ? "laptopcomputer" : "display",
                                   tint: SettingsPane.display(display.id).tint)
                            .tag(SettingsPane.display(display.id))
                    }
                    ForEach(Self.displayTools, id: \.self, content: row)
                }
                Section(tr("Mouse", "Chuột")) { ForEach(Self.mousePages, id: \.self, content: row) }
                Section(tr("Windows", "Cửa sổ")) { row(.windows) }
                Section("OneMac") { row(.general) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle("") // each page carries its own header
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .frame(minWidth: 780, minHeight: 560)
        .id(language.language) // rebuild every string when the language changes
    }

    private func row(_ pane: SettingsPane) -> some View {
        SidebarRow(title: pane.title, icon: pane.systemImage, tint: pane.tint).tag(pane)
    }

    private var detail: some View { Self.detail(for: navigator.pane) }

    @ViewBuilder
    static func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .display, .hiDPI, .brightnessKeys, .displayDiagnostics:
            HiDisplayPaneView(pane: pane)
        case .mouseGeneral, .mouseButtons, .mouseScroll, .mouseDevices, .mouseGestures:
            MousePaneView(pane: pane)
        case .windows:
            WindowsPage()
        case .general:
            GeneralPane()
        }
    }
}

/// Sidebar entry with a coloured rounded icon, as in System Settings.
private struct SidebarRow: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: FS.label, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: Rad.sm, style: .continuous).fill(tint.gradient))
        }
        .padding(.vertical, 2)
    }
}

/// App-level page: language, the utilities that also make sense in a window, and about.
struct GeneralPane: View {
    @ObservedObject private var language = LanguageSettings.shared

    var body: some View {
        SettingsPage(icon: SettingsPane.general.systemImage, tint: SettingsPane.general.tint,
                     title: SettingsPane.general.title, subtitle: SettingsPane.general.subtitle) {
            SettingsSection {
                SettingsStack(tr("Language", "Ngôn ngữ"),
                              detail: tr("Applies right away, everywhere in OneMac.", "Áp dụng ngay cho toàn bộ OneMac.")) {
                    ChipPicker(AppLanguage.allCases.map { ($0, $0.title) }, selection: $language.language)
                }
            }
            UtilityCards()
            SettingsSection(tr("About", "Giới thiệu")) {
                SettingsRow("OneMac", value: AppInfo.version, icon: "info.circle")
                SettingsRow(tr("Includes", "Bao gồm"), value: "HiDisplay \(HiDisplayModule.version) · Mousse",
                            icon: "shippingbox")
                SettingsRow(tr("License", "Giấy phép"), value: "PolyForm Noncommercial 1.0.0", icon: "doc.text")
            }
        }
    }
}
