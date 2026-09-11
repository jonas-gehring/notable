import CoreAudio
import Foundation
import IOKit

/// The CoreAudio side of `InputDevicePolicy`: which devices exist, which one is
/// the default, and whether the lid is closed.
///
/// Read-only and without a TCC grant — listing devices needs none, only opening
/// one does. Cheap enough for the dictation path: a handful of property reads.
enum AudioDevices {
    /// Alive devices with at least one input stream.
    static func inputDevices() -> [AudioDeviceInfo] {
        deviceIDs().compactMap { id in
            guard inputStreamCount(id) > 0,
                  (uint32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
            else { return nil }
            return describe(id)
        }
    }

    /// Any device, input or output.
    static func describe(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard id != kAudioObjectUnknown, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            transport: AudioTransport(coreAudio: uint32(id, kAudioDevicePropertyTransportType) ?? 0),
            isRunningSomewhere: (uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
        )
    }

    static var defaultInputID: AudioObjectID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutputID: AudioObjectID? { systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// `AppleClamshellState` from the power-management root — readable without
    /// any grant. A Mac without a lid has no such key and reads as open.
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputStreamCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), selector), id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue()
        else { return nil }
        let string = cf as String
        return string.isEmpty ? nil : string
    }
}

extension AudioTransport {
    init(coreAudio raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI:
            self = .wired
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            self = .continuity
        case kAudioDeviceTransportTypeVirtual:
            self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            self = .aggregate
        default:
            self = .other
        }
    }
}
