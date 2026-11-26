import CoreAudio

/// Answers one question for the volume keys: is sound currently going to a monitor that macOS
/// cannot turn up or down?
///
/// A DisplayPort or HDMI output has no volume control on the Mac side — the keys show the "not
/// available" badge — so that is exactly the case where the monitor's own volume, over DDC, is the
/// only one there is. Any other output is left to macOS.
enum AudioOutputProbe {

    /// The default output device's name when it is a display without a system volume control.
    static func displayOutputName() -> String? {
        guard let device = defaultOutputDevice() else { return nil }

        var transport: UInt32 = 0
        guard read(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, into: &transport),
              transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
        else { return nil }

        // Element 0 is the device's main volume, 1 the first channel; either one means macOS can
        // already do the job.
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            if AudioObjectHasProperty(device, &address) { return nil }
        }

        var name: Unmanaged<CFString>?
        guard read(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, into: &name),
              let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                   kAudioObjectPropertyScopeGlobal, into: &device),
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func read<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, into value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer($0)) == noErr
        }
    }
}
