import CoreAudio
import CoreMediaIO
import Foundation
import IOKit.pwr_mgt

/// Tells whether something on screen should not be covered: video players, calls and presentations
/// ask macOS to keep the display on, and a call keeps a camera or a microphone running. All of it is
/// visible to every process without any permission.
enum MediaActivity {
    private static let displayAssertions: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// A video, a presentation or a call is going on.
    static func isBusy() -> Bool { isAnotherAppKeepingDisplayOn() || isCameraInUse() || isMicrophoneInUse() }

    /// True while another app holds a keep-the-display-on assertion. OneMac's own keep-awake is ignored.
    static func isAnotherAppKeepingDisplayOn() -> Bool {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
              let byProcess = copied?.takeRetainedValue() as NSDictionary? else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for (pid, held) in byProcess {
            guard (pid as? NSNumber)?.int32Value != ownPID, let assertions = held as? [[String: Any]] else { continue }
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey] as? String, displayAssertions.contains(type),
                      (assertion[kIOPMAssertionLevelKey] as? Int ?? 0) != 0 else { continue }
                return true
            }
        }
        return false
    }

    /// True while any process captures from a camera.
    static func isCameraInUse() -> Bool {
        var list = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &list, 0, nil, size, &used, &devices) == noErr else { return false }
        var running = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        return devices.contains { device in
            var value: UInt32 = 0, got: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value)
            return status == noErr && value != 0
        }
    }

    /// True while any process records from an audio input. A headset that is one device for both
    /// directions also counts while it only plays; the deferral cap keeps that from blocking breaks.
    static func isMicrophoneInUse() -> Bool {
        var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &devices) == noErr else { return false }
        var inputs = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                mScope: kAudioObjectPropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return devices.contains { device in
            var streams: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputs, 0, nil, &streams) == noErr, streams > 0 else { return false }
            var value: UInt32 = 0, valueSize = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &running, 0, nil, &valueSize, &value) == noErr && value != 0
        }
    }
}
