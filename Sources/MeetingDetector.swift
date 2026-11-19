import AppKit
import CoreAudio
import CoreGraphics
import Foundation

struct DetectedCall: Equatable {
    let appName: String
    let bundleID: String
}

/// Finds a meeting app that is using the microphone.
/// macOS 14+: CoreAudio process objects say exactly which processes capture input.
/// macOS 13: the default input device is "running somewhere" and a known meeting app is running.
enum MeetingDetector {
    /// Bundle IDs of other processes that are capturing audio input right now, or nil when this
    /// macOS cannot tell (before 14).
    static func inputProcessBundleIDs(excludingPID ownPID: pid_t = getpid()) -> [String]? {
        guard #available(macOS 14.0, *) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }

        var result: [String] = []
        for object in objects {
            var running: UInt32 = 0
            guard read(object, kAudioProcessPropertyIsRunningInput, into: &running), running != 0 else { continue }
            var pid: pid_t = 0
            if read(object, kAudioProcessPropertyPID, into: &pid), pid == ownPID { continue }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr, let value = bundle?.takeRetainedValue() as String?, !value.isEmpty {
                result.append(value)
            } else if pid > 0, let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier {
                result.append(id)
            }
        }
        return result
    }

    static func defaultInputRunningSomewhere() -> Bool {
        var device = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &device), device != 0 else { return false }
        var running: UInt32 = 0
        return read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running) && running != 0
    }

    /// The meeting app using the mic, if any. `selfCapturing` is true while LocalVoice itself records
    /// (then the macOS 13 fallback cannot tell other users apart and only reports running apps).
    static func detect(selfCapturing: Bool) -> DetectedCall? {
        if let ids = inputProcessBundleIDs() {
            for id in ids {
                guard let name = MeetingApps.name(forBundleID: id) else { continue }
                if MeetingApps.isBrowser(bundleID: id) {
                    return DetectedCall(appName: MeetingApps.browserCallName(windowTitles: windowTitles()) ?? "Browser call", bundleID: id)
                }
                return DetectedCall(appName: name, bundleID: id)
            }
            return nil
        }
        // macOS 13 fallback.
        guard !selfCapturing, defaultInputRunningSomewhere() else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        let ordered = apps.sorted { ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1) }
        for app in ordered {
            guard let id = app.bundleIdentifier, let name = MeetingApps.name(forBundleID: id) else { continue }
            if MeetingApps.isBrowser(bundleID: id) {
                guard let call = MeetingApps.browserCallName(windowTitles: windowTitles(ownerPID: app.processIdentifier)) else { continue }
                return DetectedCall(appName: call, bundleID: id)
            }
            if name == "Slack huddle" && !app.isActive { continue } // Slack is always running; only trust it when in front
            return DetectedCall(appName: name, bundleID: id)
        }
        return nil
    }

    /// Whether a call is still capturing the mic (used to offer "stop recording" when the meeting ends).
    /// nil when unknown (macOS 13 while LocalVoice itself records).
    static func callStillActive(bundleID: String?) -> Bool? {
        guard let ids = inputProcessBundleIDs() else {
            guard let bundleID else { return nil }
            return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        }
        if let bundleID { return ids.contains(bundleID) }
        return ids.contains { MeetingApps.name(forBundleID: $0) != nil }
    }

    /// Window titles (they need Screen Recording permission; empty without it).
    static func windowTitles(ownerPID: pid_t? = nil) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { window in
            if let ownerPID, (window[kCGWindowOwnerPID as String] as? pid_t) != ownerPID { return nil }
            return window[kCGWindowName as String] as? String
        }
    }

    private static func read<T: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
