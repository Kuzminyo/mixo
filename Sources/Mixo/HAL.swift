import AudioToolbox
import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeUSB: "cable.connector"
        default: "speaker.wave.2"
        }
    }
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

/// Thin wrappers around the Core Audio object property API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: - Generic properties

    static func makeAddress(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func isSettable(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = makeAddress(selector, scope)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address) else { return false }
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default fallback: T
    ) -> T {
        var address = makeAddress(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : fallback
    }

    @discardableResult
    static func setValue<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ value: T
    ) -> Bool {
        var address = makeAddress(selector, scope)
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [T] {
        var address = makeAddress(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = makeAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - Output devices

    static func outputDevices() -> [OutputDevice] {
        let ids: [AudioObjectID] = array(system, kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            let streams: [AudioStreamID] = array(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            guard !streams.isEmpty,
                  let name = string(id, kAudioObjectPropertyName),
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let transport: UInt32 = value(id, kAudioDevicePropertyTransportType, default: 0)
            // Skip aggregate/virtual helpers that other apps create.
            guard transport != kAudioDeviceTransportTypeAggregate else { return nil }
            return OutputDevice(id: id, name: name, uid: uid, transport: transport)
        }
    }

    static func defaultOutputDevice() -> AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    static func setDefaultOutputDevice(_ id: AudioObjectID) {
        setValue(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, id)
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Volume

    static func canSetVolume(_ device: AudioObjectID) -> Bool {
        isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
    }

    static func volume(_ device: AudioObjectID) -> Float {
        value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, default: Float32(1))
    }

    static func setVolume(_ device: AudioObjectID, _ volume: Float) {
        setValue(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, Float32(volume))
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        value(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, default: UInt32(0)) != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        setValue(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(muted ? 1 : 0))
    }

    // MARK: - Processes

    /// Every process that has opened an audio connection, with whether it is producing sound right now.
    static func processes() -> [AudioProcess] {
        let ids: [AudioObjectID] = array(system, kAudioHardwarePropertyProcessObjectList)
        return ids.map { id in
            AudioProcess(
                objectID: id,
                pid: value(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: string(id, kAudioProcessPropertyBundleID),
                isPlaying: value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            )
        }
    }
}
