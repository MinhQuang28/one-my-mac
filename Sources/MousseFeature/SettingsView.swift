import OneMacUI
import SwiftUI

/// Routes one mouse settings page of the OneMac settings window to its view.
struct SettingsView: View {
    enum Page { case general, buttons, scroll, devices, gestures }
    let page: Page

    var body: some View {
        switch page {
        case .general: MouseGeneralPage()
        case .buttons: ButtonMappingsView()
        case .scroll: MouseScrollPage()
        case .devices: DevicesView()
        case .gestures: MouseGesturesPage()
        }
    }
}

extension SettingsPage {
    /// A mouse page takes its header from the sidebar entry, so the two can never disagree.
    init(pane: SettingsPane, @ViewBuilder content: () -> Content) {
        self.init(icon: pane.systemImage, tint: pane.tint, title: pane.title, subtitle: pane.subtitle,
                  content: content)
    }
}
