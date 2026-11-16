import Foundation
import AppKit
import CoreAudio

/// Meeting heuristics: microphone in use AND (a meeting app is running OR a browser meeting
/// tab was seen recently). Stateless apart from the browser timestamp kept by SensorHub.
enum SensorMeetingDetector {
    static let meetingApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
    ]

    static let meetingDomains = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us"]

    static func isMeetingDomain(_ domain: String?) -> Bool {
        guard let d = domain?.lowercased() else { return false }
        return meetingDomains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    static func meetingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return meetingApps.contains(id)
        }
    }

    // MARK: - Microphone (CoreAudio)

    /// True if the default input device is running in some process. Only the default input is
    /// checked: the property is device-wide, so a headset that is only playing audio would
    /// otherwise count as "microphone in use".
    static func microphoneInUse() -> Bool {
        guard let def = defaultInputDevice() else { return false }
        return isRunningSomewhere(def)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
