import AudioToolbox
import CoreAudio
import Darwin
import Foundation

func globalAddress(_ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// Host time in seconds: the clock Core Audio and AVAudioEngine timestamps use.
func hostSeconds(_ hostTime: UInt64 = AudioGetCurrentHostTime()) -> Double {
    Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
}

enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         default fallback: T) -> T {
        var address = globalAddress(selector, scope: scope)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        return status == noErr ? result : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = globalAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultDevice(input: Bool) -> AudioObjectID {
        value(system, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
              default: AudioObjectID(kAudioObjectUnknown))
    }

    static func deviceName(_ device: AudioObjectID) -> String? {
        device == kAudioObjectUnknown ? nil : string(device, kAudioObjectPropertyName)
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        device == kAudioObjectUnknown ? nil : string(device, kAudioDevicePropertyDeviceUID)
    }

    static func nominalRate(_ device: AudioObjectID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    static func transportName(_ device: AudioObjectID) -> String {
        let transport: UInt32 = value(device, kAudioDevicePropertyTransportType, default: 0)
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case 0: return "unknown"
        default: return "other"
        }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}

/// One process the audio system knows about.
struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let runningInput: Bool
    let runningOutput: Bool

    static func all() -> [AudioProcess] {
        AudioHAL.objectList(AudioHAL.system, kAudioHardwarePropertyProcessObjectList).map { object in
            let pid: pid_t = AudioHAL.value(object, kAudioProcessPropertyPID, default: -1)
            let input: UInt32 = AudioHAL.value(object, kAudioProcessPropertyIsRunningInput, default: 0)
            let output: UInt32 = AudioHAL.value(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            return AudioProcess(object: object, pid: pid,
                                bundleID: AudioHAL.string(object, kAudioProcessPropertyBundleID),
                                name: processName(pid), runningInput: input != 0, runningOutput: output != 0)
        }
    }

    /// The process's executable name, which is what daemons without a bundle
    /// ID (avconferenced, callservicesd) are known by.
    static func processName(_ pid: pid_t) -> String {
        guard pid > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            return (path as NSString).lastPathComponent
        }
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return ""
    }

    /// The app a helper belongs to, for display: "Google Chrome Helper" ->
    /// the bundle ID's first three parts give "com.google.Chrome".
    var displayName: String {
        if !name.isEmpty { return name }
        return bundleID ?? "pid \(pid)"
    }
}

func isProcessAlive(_ pid: pid_t) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}
