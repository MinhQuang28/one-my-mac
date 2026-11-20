import EyeBreakKit
import HardwareKit
import HiDisplayFeature
import MousseFeature
import OneMacUI
import SwiftUI
import WindowKit

/// OneMac — displays (HiDPI, DDC brightness), mouse, battery, temperatures, fans and keep-awake in
/// one menu-bar app.
@main
struct OneMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("OneMac", id: SettingsWindow.id) {
            SettingsWindow()
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
        // A menu-bar app: the settings window opens on request only, never at login or by restoration.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Exempts the process from App Nap: the mouse scroll animator must not lag after idle time.
    private var noNapActivity: NSObjectProtocol?
    private var terminationStarted = false
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let preview = PreviewRenderer.requested {
            preview.run()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        noNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Real-time mouse input processing")
        HardwareMonitor.shared.start()
        SystemUsageMonitor.shared.start()
        FanController.shared.start()
        EyeBreaks.shared.start()
        // Everything that may ask for Accessibility waits for the stale grants to be reset first.
        AccessibilityRecovery.clearStaleGrants {
            MouseModule.start()
            WindowSnapping.shared.start()
            Task { await HiDisplayModule.start() }
        }
    }

    /// Fans back to System, mouse config flushed, display dimming cleared — all before exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard PreviewRenderer.requested == nil else { return .terminateNow }
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        AccessibilityRecovery.rememberGrant()
        FanController.shared.restoreSystemSync()
        KeepAwake.shared.deactivate()
        MouseModule.stop()
        WindowSnapping.shared.stop()
        EyeBreaks.shared.stop()
        Task {
            await HiDisplayModule.stop()
            reply(sender)
        }
        // A stalled profile flush must not turn Quit into Force Quit.
        Task {
            try? await Task.sleep(for: .seconds(3))
            reply(sender)
        }
        return .terminateLater
    }

    private func reply(_ app: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        app.reply(toApplicationShouldTerminate: true)
    }
}
