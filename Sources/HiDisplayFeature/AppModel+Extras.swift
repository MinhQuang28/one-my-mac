import HiDisplayKit

/// Volume, contrast and input source of external monitors, over the same DDC session as brightness.
///
/// Read on demand rather than at every settle: three more reads per display on each replug would
/// slow the brightness probe for values most sessions never look at.
extension AppModel {

    /// Reads a display's extras once. `force` re-reads, for a page that wants what the monitor says
    /// now — its own buttons can change all three behind the app's back.
    func loadExtras(for display: DisplayDevice, force: Bool = false) async {
        let key = display.id
        guard !display.isBuiltIn, brightness.hasDDC(key), !extrasLoading.contains(key),
              force || extras[key] == nil else { return }
        extrasLoading.insert(key)
        defer { extrasLoading.remove(key) }

        var loaded = DisplayExtras()
        loaded.volume = await level(.volume, of: display)
        loaded.contrast = await level(.contrast, of: display)
        if let reply = try? await brightness.readDDCFeature(.inputSource, for: display) {
            // The high byte is undefined for this code and non-zero on some monitors.
            loaded.inputSource = reply.current & 0xFF
        }
        extras[key] = loaded
    }

    private func level(_ code: VCPCode, of display: DisplayDevice) async -> DisplayExtras.Level? {
        guard let reply = try? await brightness.readDDCFeature(code, for: display) else { return nil }
        return DisplayExtras.Level(
            value: VCPCodec.normalized(fromRaw: reply.current, minimum: 0, maximum: reply.maximum),
            maximum: reply.maximum)
    }

    /// Forgets what was read for displays that are gone, so a reconnect reads again.
    func pruneExtras(keeping displays: [DisplayDevice]) {
        let live = Set(displays.map(\.id))
        extras = extras.filter { live.contains($0.key) }
        volumeBeforeMute = volumeBeforeMute.filter { live.contains($0.key) }
    }

    func setVolume(_ value: Float, for display: DisplayDevice) {
        setLevel(\.volume, code: .volume, to: value, for: display)
    }

    func setContrast(_ value: Float, for display: DisplayDevice) {
        setLevel(\.contrast, code: .contrast, to: value, for: display)
    }

    private func setLevel(
        _ path: WritableKeyPath<DisplayExtras, DisplayExtras.Level?>, code: VCPCode,
        to value: Float, for display: DisplayDevice
    ) {
        guard let level = extras[display.id]?[keyPath: path] else { return }
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - level.value) > 0.0005 else { return }
        extras[display.id]?[keyPath: path]?.value = clamped
        let raw = VCPCodec.rawValue(fromNormalized: clamped, minimum: 0, maximum: level.maximum)
        Task { try? await brightness.writeDDCFeature(code, raw: raw, for: display) }
    }

    /// Switches the monitor to another input. The caller confirms first: on an input with nothing
    /// connected the monitor goes dark and can only be brought back with its own buttons.
    func setInputSource(_ raw: UInt16, for display: DisplayDevice) {
        guard extras[display.id]?.inputSource != nil else { return }
        extras[display.id]?.inputSource = raw
        Task { try? await brightness.writeDDCFeature(.inputSource, raw: raw, for: display) }
    }

    // MARK: - Volume keys

    /// The monitor the volume keys should drive right now, if any: sound must be going to a
    /// display macOS cannot adjust (see `AudioOutputProbe`), and that display must speak DDC.
    private func volumeKeyTarget() -> DisplayDevice? {
        guard let name = AudioOutputProbe.displayOutputName() else { return nil }
        let candidates = displays.filter { !$0.isBuiltIn && brightness.hasDDC($0.id) }
        // The audio device is normally named after the monitor. With one candidate there is nothing
        // to tell apart, so a renamed or oddly reported device still works.
        return candidates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? (candidates.count == 1 ? candidates[0] : nil)
    }

    /// - Returns: true when the press was applied to a monitor and macOS should not see it.
    func handleVolumeKey(_ key: VolumeKey, fine: Bool) -> Bool {
        guard volumeKeysEnabled, let display = volumeKeyTarget() else { return false }
        if let loaded = extras[display.id] {
            guard loaded.volume != nil else { return false }
            applyVolumeKey(key, fine: fine, to: display)
        } else {
            // First press since the display appeared: read its volume, then apply the press.
            Task {
                await loadExtras(for: display)
                applyVolumeKey(key, fine: fine, to: display)
            }
        }
        return true
    }

    private func applyVolumeKey(_ key: VolumeKey, fine: Bool, to display: DisplayDevice) {
        guard let current = extras[display.id]?.volume?.value else { return }
        // Sixteen steps like the system's volume HUD, a quarter of that with ⌥⇧.
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let next: Float
        switch key {
        case .up: next = min(current + step, 1)
        case .down: next = max(current - step, 0)
        case .mute:
            // Not VCP 0x8D: too few monitors implement it. Zero and back does the same job.
            if current > 0 {
                volumeBeforeMute[display.id] = current
                next = 0
            } else {
                next = volumeBeforeMute.removeValue(forKey: display.id) ?? 0.25
            }
        }
        setVolume(next, for: display)
        osd.show(value: next, display: display, icon: next > 0 ? "speaker.wave.2" : "speaker.slash")
    }
}
