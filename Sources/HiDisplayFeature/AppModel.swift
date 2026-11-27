import AppKit
import Combine
import Foundation
import HiDisplayKit
import OneMacUI
import SwiftUI

/// Single source of truth for the UI.
///
/// Wires discovery → brightness → profiles together so no view has to know about display events, and
/// so all the ordering rules (probe after settle, persist after change, restore after probe) live in
/// one place rather than being re-derived per view.
@MainActor
final class AppModel: ObservableObject {

    static let version = "0.8.0"
    /// One instance for the process. `AppDelegate` needs to reach the same object the scene shows in
    /// order to tear down shade windows and flush profiles on quit.
    static let shared = AppModel()

    let discovery = DisplayDiscoveryService()
    let brightness = BrightnessCoordinator()
    let profiles = ProfileStore()

    @Published var displays: [DisplayDevice] = []
    @Published var ambiguousKeys: Set<String> = []
    /// Last diagnostics export path, shown in Settings after an export.
    @Published var lastExportPath: String?
    @Published var isExportingDiagnostics = false
    // One error slot per place it is shown. A single shared `lastError` put a failed diagnostics
    // export under the Resolution picker and a failed resolution change on the Diagnostics page.
    /// The last resolution change that failed or could not be reverted. Shown with the picker.
    @Published var modeChangeError: String?
    /// True while a resolution change, or its keep/revert dialog, is in flight.
    @Published private(set) var isChangingMode = false
    /// The last diagnostics export that failed. Shown on the Diagnostics page.
    @Published var diagnosticsError: String?
    /// A log-out or restart request that macOS refused. Shown where the request was made.
    @Published var sessionEndError: String?
    private var stopped = false

    // MARK: Settings navigation

    /// The display the Settings window is about: the sidebar row, the HiDPI page's picker and the
    /// menu all read this one value, so choosing a monitor in one place carries to the others.
    /// `nil` only before any display has been enumerated.
    @Published var selectedDisplayID: String?
    /// The sidebar entry the user last picked. `nil` until they pick one, in which case the window
    /// opens on the selected display — see `resolvedSettingsRoute`.
    @Published private(set) var settingsRoute: SettingsRoute?

    /// The page to show now. Falls back to the selected display, then General, so the window never
    /// opens on a blank detail pane.
    var resolvedSettingsRoute: SettingsRoute {
        if let settingsRoute { return settingsRoute }
        if let selectedDisplayID { return .display(selectedDisplayID) }
        return .general
    }

    func navigate(to route: SettingsRoute) {
        if let id = route.displayID { selectedDisplayID = id }
        settingsRoute = route
    }

    /// Keeps the selection and route pointing at a display that exists.
    ///
    /// Runs on every display change, not only while Settings is open: a route left pointing at a
    /// monitor that was unplugged with the window closed would open onto nothing. The fallback
    /// prefers an external display, which is what both the display page and HiDPI are for.
    private func reconcileSelection(with displays: [DisplayDevice]) {
        let live = Set(displays.map(\.id))
        let preferred = displays.first { !$0.isBuiltIn }?.id ?? displays.first?.id
        if selectedDisplayID.map({ !live.contains($0) }) ?? true {
            selectedDisplayID = preferred
        }
        if let id = settingsRoute?.displayID, !live.contains(id) {
            settingsRoute = preferred.map(SettingsRoute.display) ?? .general
        }
    }

    // MARK: Brightness keys

    @Published var brightnessKeysEnabled = false
    @Published var brightnessKeyTarget: BrightnessKeyTarget = .displayUnderMouse
    /// Mirrors the Accessibility permission so Settings can react without polling from the view.
    @Published var isAccessibilityTrusted = BrightnessKeyTap.isAccessibilityTrusted
    private let keyTap = BrightnessKeyTap()
    let osd = BrightnessOSD()

    // MARK: Volume, contrast, input (see `AppModel+Extras.swift`)

    /// Present once a display's extras have been read.
    @Published var extras: [String: DisplayExtras] = [:]
    var extrasLoading: Set<String> = []
    var volumeBeforeMute: [String: Float] = [:]
    @Published var volumeKeysEnabled = false
    /// One event tap serves both kinds of key, so it runs while either is wanted.
    private var keysWanted: Bool { brightnessKeysEnabled || volumeKeysEnabled }
    private var permissionWatch: Task<Void, Never>?

    /// App-level preferences live in UserDefaults rather than the profile store: they are not
    /// per-display, and they must be readable before any display has been enumerated.
    private enum DefaultsKey {
        static let keysEnabled = "brightnessKeysEnabled"
        static let keyTarget = "brightnessKeyTarget"
        static let volumeKeysEnabled = "volumeKeysEnabled"
    }

    private var cancellables: Set<AnyCancellable> = []
    /// Cached so a slider change does not have to await the actor just to know the saved value.
    var savedBrightness: [String: Float] = [:]
    /// Saved settings for displays, connected or not, for the list in Settings. See
    /// `AppModel+Profiles.swift`.
    @Published var savedProfiles: [DisplayProfile] = []
    @Published var profileMessage: String?
    @Published var profileError: String?

    init() {
        // SwiftUI does not propagate changes through a nested ObservableObject: views observe
        // `AppModel`, so `brightness`'s own `@Published` updates would never invalidate them. The
        // slider still worked (it keeps its own drag state and the binding writes straight through),
        // which is what made this easy to miss — but everything *asynchronous* was invisible: the
        // percentage after Reset Dimming, the controller label once a probe finished, the warning when
        // a hardware write failed and forced a re-probe.
        brightness.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Read through the cache rather than the profile actor: the coordinator needs this answer
        // synchronously, mid-probe, and the cache is refreshed whenever a value is written.
        brightness.savedBrightnessLookup = { [weak self] key in self?.savedBrightness[key] }

        discovery.$displays
            .sink { [weak self] displays in
                guard let self else { return }
                self.displays = displays
                self.reconcileSelection(with: displays)
                self.brightness.handleDisplaysChanged(displays)
            }
            .store(in: &cancellables)

        discovery.$ambiguousKeys
            .assign(to: &$ambiguousKeys)

        // Undebounced, so a dimmed display is not left at full brightness for the length of the
        // settle delay every time the resolution changes. Write-only and synchronous — see
        // `DisplayDiscoveryService.reconfigured`.
        discovery.reconfigured
            .sink { [weak self] in self?.brightness.reapplySoftwareDimming() }
            .store(in: &cancellables)

        discovery.settled
            .sink { [weak self] displays in
                Task { await self?.handleSettled(displays) }
            }
            .store(in: &cancellables)

        keyTap.onBrightnessKey = { [weak self] delta, allDisplays in
            self?.handleBrightnessKey(delta: delta, forceAllDisplays: allDisplays) ?? false
        }
        keyTap.onVolumeKey = { [weak self] key, fine in
            self?.handleVolumeKey(key, fine: fine) ?? false
        }
        keyTap.onTrustLost = { [weak self] in
            guard let self else { return }
            self.isAccessibilityTrusted = false
            // Still wanted: pick the tap back up if the permission returns.
            if self.keysWanted { self.startWatchingForPermission() }
        }

        // A monitor sleep/wake cycle can replace a display's IOAVService without any display
        // reconfiguration event — the display never "disconnects", so discovery stays quiet while
        // the DDC session underneath is dead. Worse, if a probe ran while the monitor slept, the
        // display downgraded to software dimming, and nothing on that path ever re-probes. Screens
        // waking is the moment to re-check what every external display can actually do, and to put
        // the user's brightness back on a monitor that woke on its own OSD value.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.brightness.handleScreensDidWake(self.displays)
                    await self.persistDDCFacts(for: self.displays)
                }
            }
            .store(in: &cancellables)

        // Fast user switching is the same hazard without the notification above: while another
        // session owned the displays, monitors may have slept, been replugged or been driven to
        // another brightness, and coming back produces neither a wake nor a reconfiguration.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.brightness.handleScreensDidWake(self.displays)
                    await self.persistDDCFacts(for: self.displays)
                }
            }
            .store(in: &cancellables)
    }

    func start() async {
        let defaults = UserDefaults.standard
        brightnessKeysEnabled = defaults.bool(forKey: DefaultsKey.keysEnabled)
        volumeKeysEnabled = defaults.bool(forKey: DefaultsKey.volumeKeysEnabled)
        if let raw = defaults.string(forKey: DefaultsKey.keyTarget),
           let target = BrightnessKeyTarget(rawValue: raw) {
            brightnessKeyTarget = target
        }
        // Re-arm the tap on launch, but only if permission is still granted — the user may have
        // revoked it since, and starting must not re-prompt on every launch.
        isAccessibilityTrusted = BrightnessKeyTap.isAccessibilityTrusted
        // Enabled but not trusted means revoked, or the app was re-signed and macOS dropped the
        // grant. Watch without prompting, so granting it in System Settings is enough; this used
        // to need the switch toggled off and on again.
        syncKeyTap(promptIfNeeded: false)

        await profiles.load()
        let assignments = await profiles.userAssignments()
        await reloadSavedProfiles()

        // Feed user identity pins in before the first enumeration, so a pinned display is recognised
        // on the very first pass rather than being briefly treated as new.
        discovery.setUserAssignments(assignments)
        discovery.start()

        // A previous run that died mid soft-reconnect left a display switched off; it stays off
        // until something turns it back on. Not awaited — launch must not wait on a link handshake.
        Task { await DisplayReconnector.recoverStranded() }

        // The first configuration never produces a reconfiguration callback, so probe explicitly.
        await handleSettled(discovery.displays)
    }

    /// Clean-quit cleanup. Idempotent, because `applicationShouldTerminate` awaits it and holds
    /// termination open until it returns; a second call must not tear anything down twice.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        osd.hide()
        keyTap.stop()
        permissionWatch?.cancel()
        discovery.stop()
        brightness.prepareForQuit()
        // Any change still inside the save debounce is lost without this. It used to block the
        // main thread on a semaphore from `applicationWillTerminate`; the delegate now replies
        // `.terminateLater` and lets the flush finish properly.
        await profiles.flush()
    }

    func handleSettled(_ displays: [DisplayDevice]) async {
        // Saved overrides and DDC facts go in *before* the probe pass, so the one probe per display
        // resolves against them. The old order — probe, then `setUserOverride` — re-probed every
        // display that had a saved controller (two full DDC cycles on the bus per settle), and the
        // brightness restore in between ran on the pre-override controller.
        for display in displays {
            let profile = await profiles.profile(for: display.id)
            brightness.seedUserOverride(profile?.brightnessController, for: display.id)
            if let facts = await profiles.ddcFacts(for: display.id) {
                await brightness.seedDDCFacts(facts, for: display.id)
            }
        }

        await brightness.handleSettledDisplays(displays)
        await persistDDCFacts(for: displays)
        pruneExtras(keeping: displays)
        // Only the list Settings shows. The brightness cache is deliberately not rebuilt here: a
        // slider change still on its way to the store would be overwritten by the older value.
        savedProfiles = await profiles.allProfiles()
    }

    /// Persists what the probes just learned. Settle and wake are the moments this is fresh and
    /// cheap; a frame shape that flips mid-session (an OSD toggle) is picked up at the next one,
    /// which is when it matters again.
    func persistDDCFacts(for displays: [DisplayDevice]) async {
        for display in displays where brightness.controller(for: display.id) == .ddc {
            if let facts = await brightness.ddcFacts(for: display.id) {
                await profiles.setDDCFacts(facts, for: display)
            }
        }
    }

    // MARK: - Actions

    /// - Parameter force: sends the write even when state says nothing changed. For the paths whose
    ///   entire purpose is re-asserting a value against hardware that may have drifted — Sync
    ///   Displays — because a DDC write can fail silently and state then lies.
    func setBrightness(_ value: Float, for display: DisplayDevice, force: Bool = false) {
        // No controller yet means the first probe has not finished (or found nothing). The
        // coordinator would drop the write, but the value would still be cached and saved here —
        // and the probe, when it lands, "restores" that value over the one the user really had.
        guard brightness.controller(for: display.id) != nil else { return }
        // A held brightness key repeats its clamped value at 0%/100%, and a slider can report the
        // same position twice; each duplicate still queued a DDC frame and re-armed the profile
        // save debounce. Skip only when both the saved value and the coordinator's requested value
        // already match, so a probe re-seeding the UI can never make a real change look redundant.
        if !force,
           let saved = savedBrightness[display.id],
           abs(saved - value) < 0.0005,
           abs(brightness.brightness(for: display.id) - value) < 0.0005 {
            return
        }
        savedBrightness[display.id] = value
        Task {
            await brightness.setBrightness(value, for: display)
            await profiles.setBrightness(value, for: display)
        }
    }

    func setController(_ kind: BrightnessControllerKind?, for display: DisplayDevice) {
        brightness.setUserOverride(kind, for: display)
        Task { await profiles.setController(kind, for: display) }
    }

    /// Every display this app is allowed to drive. The built-in panel is macOS's — see
    /// `BrightnessControllerResolver.resolve`.
    var brightnessManagedDisplays: [DisplayDevice] { displays.filter { !$0.isBuiltIn } }

    /// Applies one value to every external display. The source is the main display when that is itself
    /// external, so "sync" means "match this screen" — but never the built-in one, whose value this app
    /// does not read: taking it as the source would push a default of 100% onto every monitor.
    func syncAllDisplays() {
        let managed = brightnessManagedDisplays
        let source = managed.first(where: \.isMain) ?? managed.first
        // A source that is still being probed has no value of its own yet; `brightness(for:)`
        // answers 100% for it, and syncing that would blast every other monitor to full.
        guard let source, brightness.states[source.id] != nil else { return }
        let value = brightness.brightness(for: source.id)
        for display in managed where display.id != source.id {
            // Forced: "sync" is the user's tool for re-asserting a value, including onto a monitor
            // whose hardware silently missed an earlier fire-and-forget write.
            setBrightness(value, for: display, force: true)
        }
    }

    func resetDimming() {
        brightness.resetAllDimming()
        // Only software-dimmed displays actually changed: the reset deliberately leaves DDC and
        // native backlights alone, so seeding 1.0 for those would make the UI claim 100% while the
        // hardware sits wherever it was — and the no-op guard would then swallow the key press
        // trying to fix it.
        for display in brightnessManagedDisplays
        where brightness.controller(for: display.id)?.isHardware != true {
            savedBrightness[display.id] = 1.0
            Task { await profiles.setBrightness(1.0, for: display) }
        }
        if let external = displays.first(where: { !$0.isBuiltIn }) {
            osd.show(value: brightness.brightness(for: external.id), display: external)
        }
    }

    /// Confirms an ambiguous display as a distinct monitor, pinning its identity permanently.
    ///
    /// The pin renames the display's key, so everything keyed by the old one has to follow: the
    /// saved profile moves, the brightness cache moves, and the display is probed under its new
    /// key — discovery republishes synchronously here and fires no settle of its own, which used
    /// to leave the pinned display on "Checking brightness control…" until the next replug.
    func pinIdentity(for display: DisplayDevice) {
        // Already pinned: its key is the pin. Pinning again would only add a second assignment.
        guard display.identity.userAssignedID == nil else { return }
        let uuid = UUID()
        let oldKey = display.id
        let newKey = "user-\(uuid.uuidString.lowercased())"
        Task {
            await profiles.assignIdentity(uuid, toHeuristicKey: oldKey)
            await profiles.moveProfile(from: oldKey, to: newKey)
            await reloadSavedProfiles()
            discovery.setUserAssignments(await profiles.userAssignments())
            await handleSettled(discovery.displays)
        }
    }

    /// Probes a display again on request. For a display stuck on "Waiting for DDC…".
    func retryBrightnessProbe(for display: DisplayDevice) {
        Task { await brightness.retryProbe(for: display) }
    }

    /// Stops waiting for DDC on a held display and dims it in software now.
    func useSoftwareDimmingNow(for display: DisplayDevice) {
        Task { await brightness.useSoftwareDimmingNow(for: display) }
    }

    // MARK: - Brightness keys

    func setBrightnessKeysEnabled(_ enabled: Bool) {
        brightnessKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.keysEnabled)
        syncKeyTap(promptIfNeeded: enabled)
    }

    func setVolumeKeysEnabled(_ enabled: Bool) {
        volumeKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.volumeKeysEnabled)
        syncKeyTap(promptIfNeeded: enabled)
    }

    /// Starts or stops the tap to match the two switches.
    private func syncKeyTap(promptIfNeeded: Bool) {
        guard keysWanted else {
            keyTap.stop()
            permissionWatch?.cancel()
            return
        }
        if !keyTap.start() {
            // Not yet trusted. Prompt, then watch for the grant — macOS posts no notification for this,
            // and the user has to leave the app to grant it, so polling briefly is the only way to pick
            // the permission up without making them toggle the switch again.
            if promptIfNeeded { BrightnessKeyTap.requestAccessibility() }
            startWatchingForPermission()
        }
    }

    func setBrightnessKeyTarget(_ target: BrightnessKeyTarget) {
        brightnessKeyTarget = target
        UserDefaults.standard.set(target.rawValue, forKey: DefaultsKey.keyTarget)
    }

    /// Brings the published permission state and the tap in line with the system's current answer.
    ///
    /// macOS posts nothing when Accessibility is granted or revoked, so the page that shows the
    /// state calls this while it is visible. That covers both directions: a grant made in System
    /// Settings starts the tap, and a revocation removes it instead of leaving "Granted" on screen
    /// over a tap that can no longer work.
    func refreshAccessibilityState() {
        let trusted = BrightnessKeyTap.isAccessibilityTrusted
        if isAccessibilityTrusted != trusted { isAccessibilityTrusted = trusted }
        guard keysWanted else { return }
        if trusted {
            if !keyTap.isRunning { keyTap.start() }
        } else if keyTap.isRunning {
            keyTap.stop()
            startWatchingForPermission()
        }
    }

    /// Polls once a second until Accessibility is granted, then starts the tap. A main-actor task
    /// rather than a `Timer`: it cancels cleanly and needs no isolation assumptions.
    private func startWatchingForPermission() {
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.isAccessibilityTrusted = BrightnessKeyTap.isAccessibilityTrusted
                guard self.isAccessibilityTrusted else { continue }
                if self.keysWanted { self.keyTap.start() }
                return
            }
        }
    }

    /// Applies a brightness key press.
    ///
    /// - Returns: true when every adjusted display was external, which tells the tap it may consume the
    ///   event. Returning false keeps macOS in the loop so it can drive the built-in panel and show its
    ///   own HUD, rather than this app having to reimplement both.
    private func handleBrightnessKey(delta: Float, forceAllDisplays: Bool) -> Bool {
        guard brightnessKeysEnabled, !displays.isEmpty else { return false }

        // CoreGraphics' flipped global space, matching `DisplayDevice.frame`.
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let targets = BrightnessKeyResolver.targets(
            strategy: brightnessKeyTarget,
            displays: displays,
            pointer: pointer,
            forceAllDisplays: forceAllDisplays)
        guard !targets.isEmpty else { return false }

        var adjusted = false
        var systemMustSee = false
        var waiting = false
        for display in targets {
            switch BrightnessKeyResolver.handling(
                for: display, controller: brightness.controller(for: display.id),
                phase: brightness.phase(for: display.id)) {
            case .leaveToSystem:
                systemMustSee = true
            case .wait:
                waiting = true
            case .ignore:
                break
            case .adjust:
                let current = brightness.brightness(for: display.id)
                let next = BrightnessKeyResolver.adjusted(current, by: delta)
                setBrightness(next, for: display)
                // Only for displays this app drives: macOS draws its own HUD for the panels it
                // owns, and two indicators side by side would look like a bug.
                osd.show(value: next, display: display)
                adjusted = true
            }
        }

        // Consumed when the press was entirely this app's business — including a display whose
        // first probe is still running, where passing the key on would dim the built-in panel
        // instead of the screen the user meant.
        return (adjusted || waiting) && !systemMustSee
    }

    // MARK: - Resolution

    /// Applies a display mode, then refreshes so the UI reflects whatever actually took effect —
    /// which may be the previous mode, if the change was reverted.
    ///
    /// The switch runs off the main thread, so a second request arriving while one is in flight
    /// (or while its keep/revert dialog is up) is dropped rather than queued behind it.
    func setMode(_ mode: DisplayMode, for display: DisplayDevice) {
        guard !isChangingMode else { return }
        isChangingMode = true
        Task {
            let outcome = await ModeChangeCoordinator.change(to: mode, on: display)
            isChangingMode = false
            switch outcome {
            case .kept, .reverted:
                modeChangeError = nil
            case .failed(let message):
                modeChangeError = tr("Could not change resolution: \(message)",
                                     "Không đổi được độ phân giải: \(message)")
            }
            refreshAfterModeChange()
        }
    }

    /// A resolution change invalidates cached frames, and shade overlays are positioned from them.
    /// It also clears the gamma ramp, which `handleDisplaysChanged` puts back — the reconfiguration
    /// callback normally gets there first, but this path does not depend on that.
    func refreshAfterModeChange() {
        discovery.refreshNow()
        brightness.handleDisplaysChanged(displays)
    }

    // MARK: - Diagnostics

    /// Writes the support report, after talking to every external display over DDC.
    ///
    /// The conversation is what makes the file worth sending: a probe result says a monitor did not
    /// answer, the recorded frames say whether it could not be reached, refused, or ignored a write.
    func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        Task {
            let traces = await brightness.ddcTraces(for: displays)
            let log = await Task.detached { RecentLog.lines() }.value
            writeDiagnostics(ddcTraces: traces, recentLog: log)
            isExportingDiagnostics = false
        }
    }

    private func writeDiagnostics(ddcTraces: [DDCTrace], recentLog: [String]) {
        let report = DiagnosticsBuilder.build(
            displays: displays,
            ambiguousKeys: ambiguousKeys,
            brightnessStates: brightness.states,
            availability: brightness.availability,
            probeDetails: brightness.probeDetails,
            warnings: brightness.warnings,
            // Tolerant of a repeated key: a report is exactly what gets exported when identity
            // has gone wrong, and trapping on the duplicate would lose the evidence.
            chosenControllers: Dictionary(
                displays.compactMap { display in
                    brightness.controller(for: display.id).map { (display.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }),
            appVersion: Self.version,
            ddcTraces: ddcTraces,
            recentLog: recentLog)

        do {
            let data = try report.jsonData()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let url = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .appendingPathComponent("HiDisplay-diagnostics-\(formatter.string(from: Date())).json")
            guard let url else { return }
            try data.write(to: url, options: .atomic)
            lastExportPath = url.path
            diagnosticsError = nil
            Log.app.notice("wrote diagnostics to \(url.lastPathComponent, privacy: .public)")
        } catch {
            diagnosticsError = tr("Could not write diagnostics: \(error.localizedDescription)",
                                  "Không ghi được chẩn đoán: \(error.localizedDescription)")
        }
    }
}
