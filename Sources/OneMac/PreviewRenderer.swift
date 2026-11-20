import HardwareKit
import HiDisplayFeature
import MousseFeature
import OneMacUI
import SwiftUI

/// Development aid: `ONEMAC_PREVIEW_OUT=/path/panel.png [ONEMAC_PREVIEW_TAB=0..3]` renders the panel
/// to a PNG and exits — no menu-bar click or Screen Recording permission needed.
/// `ONEMAC_PREVIEW_PANE=mouseGeneral|mouseButtons|mouseScroll|mouseDevices|mouseGestures|general`
/// renders that settings-window page instead (`ONEMAC_PREVIEW_HEIGHT` sets its height, default 900).
@MainActor
struct PreviewRenderer {
    let output: URL
    let tab: Int
    let pane: SettingsPane?
    let paneHeight: CGFloat
    /// `ONEMAC_PREVIEW_PANE=display`: the page of the first connected display.
    let showFirstDisplay: Bool

    private static let panes: [String: SettingsPane] = [
        "mouseGeneral": .mouseGeneral, "mouseButtons": .mouseButtons, "mouseScroll": .mouseScroll,
        "mouseDevices": .mouseDevices, "mouseGestures": .mouseGestures, "general": .general,
        "windows": .windows, "eyeBreaks": .eyeBreaks, "hiDPI": .hiDPI, "brightnessKeys": .brightnessKeys, "displayDiagnostics": .displayDiagnostics,
    ]

    static var requested: PreviewRenderer? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ONEMAC_PREVIEW_OUT"], !path.isEmpty else { return nil }
        return PreviewRenderer(output: URL(fileURLWithPath: path), tab: Int(env["ONEMAC_PREVIEW_TAB"] ?? "") ?? 2,
                               pane: env["ONEMAC_PREVIEW_PANE"].flatMap { panes[$0] },
                               paneHeight: CGFloat(Double(env["ONEMAC_PREVIEW_HEIGHT"] ?? "") ?? 900),
                               showFirstDisplay: env["ONEMAC_PREVIEW_PANE"] == "display")
    }

    func run() {
        HardwareMonitor.shared.start()
        FanController.shared.start(readOnly: true)
        SystemUsageMonitor.shared.start()
        SystemUsageMonitor.shared.setVisible(true)
        ChargeLimit.shared.refresh()
        Task {
            await HiDisplayModule.start()
            try? await Task.sleep(for: .seconds(2.5)) // let sensors, battery and display probes land
            if showFirstDisplay, let display = DisplayDirectory.shared.displays.first {
                await renderInWindow(SettingsWindow.detail(for: .display(display.id)),
                                     size: NSSize(width: 700, height: paneHeight))
            } else if let pane {
                await renderInWindow(SettingsWindow.detail(for: pane), size: NSSize(width: 700, height: paneHeight))
            } else {
                let view = PanelView(flatLayout: true, previewTab: PanelTab(rawValue: tab) ?? .hardware)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                write(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            }
            exit(0)
        }
    }

    /// Settings pages scroll, and `ImageRenderer` draws nothing inside a ScrollView — so they are
    /// laid out in a real (off-screen) window and captured from its backing store instead.
    private func renderInWindow(_ view: some View, size: NSSize) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1)) // first layout pass + async state (.task, timelines)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        if let rep { host.cacheDisplay(in: host.bounds, to: rep) }
        write(rep)
    }

    private func write(_ rep: NSBitmapImageRep?) {
        guard let png = rep?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: output)
    }
}
