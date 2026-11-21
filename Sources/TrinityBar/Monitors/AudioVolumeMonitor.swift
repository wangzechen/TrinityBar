import Foundation
import CoreAudio
import AudioToolbox

struct AudioDeviceItem: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transportLabel: String
    let symbolName: String
    let channelCount: Int
    let sampleRateHz: Double?
    let isSelected: Bool
}

private let audioPropertyCallback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let rawBits = Int(bitPattern: clientData)
    Task { @MainActor in
        guard let ptr = UnsafeRawPointer(bitPattern: rawBits) else { return }
        let monitor = Unmanaged<AudioVolumeMonitor>.fromOpaque(ptr).takeUnretainedValue()
        monitor.refresh()
    }
    return noErr
}

@MainActor
final class AudioVolumeMonitor: ObservableObject {
    @Published private(set) var volume: Float = 0.5
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var outputDeviceName: String = "Output"
    @Published private(set) var outputTransportLabel: String = "System Output"
    @Published private(set) var outputSymbolName: String = "hifispeaker.fill"
    @Published private(set) var outputSampleRateHz: Double?
    @Published private(set) var outputChannelCount: Int = 2

    @Published private(set) var outputDevices: [AudioDeviceItem] = []
    @Published private(set) var inputDevices: [AudioDeviceItem] = []
    @Published private(set) var defaultInputDeviceName: String?

    var effectiveProgress: Double {
        isMuted ? 0.0 : Double(min(1.0, max(0.0, volume)))
    }

    var volumeDots: Int {
        if isMuted || volume <= 0.01 { return 0 }
        if volume < 0.28 { return 1 }
        if volume < 0.53 { return 2 }
        if volume < 0.78 { return 3 }
        return 4
    }

    nonisolated(unsafe) private var observedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var softMutedRestoreVolume: Float?

    init() {
        refresh()
        observeSystemAudioChanges()
    }

    deinit {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(systemObj, &defaultOutAddr, audioPropertyCallback, selfPtr)

        var defaultInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(systemObj, &defaultInAddr, audioPropertyCallback, selfPtr)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(systemObj, &devicesAddr, audioPropertyCallback, selfPtr)

        if observedDeviceID != kAudioObjectUnknown {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(observedDeviceID, &volAddr, audioPropertyCallback, selfPtr)

            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(observedDeviceID, &muteAddr, audioPropertyCallback, selfPtr)
        }
    }

    private func observeSystemAudioChanges() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(systemObj, &defaultOutAddr, audioPropertyCallback, selfPtr)

        var defaultInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(systemObj, &defaultInAddr, audioPropertyCallback, selfPtr)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(systemObj, &devicesAddr, audioPropertyCallback, selfPtr)

        attachDeviceListenersIfNeeded()
    }

    private func attachDeviceListenersIfNeeded() {
        let deviceID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown, deviceID != observedDeviceID else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        if observedDeviceID != kAudioObjectUnknown {
            var oldVolAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(observedDeviceID, &oldVolAddr, audioPropertyCallback, selfPtr)

            var oldMuteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(observedDeviceID, &oldMuteAddr, audioPropertyCallback, selfPtr)
        }

        observedDeviceID = deviceID
        softMutedRestoreVolume = nil

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(deviceID, &volAddr, audioPropertyCallback, selfPtr)

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(deviceID, &muteAddr, audioPropertyCallback, selfPtr)
    }

    func refresh() {
        attachDeviceListenersIfNeeded()

        let currentOutID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let currentInID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)

        let allIDs = Self.allAudioDeviceIDs()
        var outs: [AudioDeviceItem] = []
        var ins: [AudioDeviceItem] = []

        for id in allIDs {
            if Self.isHiddenDevice(id) { continue }
            guard let name = Self.readDeviceName(id) else { continue }
            let transport = Self.readTransportType(id)
            let transportText = Self.transportLabel(for: transport, name: name)
            let sampleRate = Self.readNominalSampleRate(id)

            let outCh = Self.channelCount(for: id, scope: kAudioDevicePropertyScopeOutput)
            if outCh > 0 && (id == currentOutID || Self.canBeDefaultDevice(id, scope: kAudioDevicePropertyScopeOutput)) {
                outs.append(
                    AudioDeviceItem(
                        id: id,
                        name: name,
                        transportLabel: transportText,
                        symbolName: Self.outputSymbol(for: transport, name: name),
                        channelCount: outCh,
                        sampleRateHz: sampleRate,
                        isSelected: id == currentOutID
                    )
                )
            }

            let inCh = Self.channelCount(for: id, scope: kAudioDevicePropertyScopeInput)
            if inCh > 0 && (id == currentInID || Self.canBeDefaultDevice(id, scope: kAudioDevicePropertyScopeInput)) {
                ins.append(
                    AudioDeviceItem(
                        id: id,
                        name: name,
                        transportLabel: transportText,
                        symbolName: Self.inputSymbol(for: transport, name: name),
                        channelCount: inCh,
                        sampleRateHz: sampleRate,
                        isSelected: id == currentInID
                    )
                )
            }
        }

        // Put Bluetooth & Built-in devices nicely ordered (Selected or Built-in/Bluetooth cleanly sorted by name, keeping stable order)
        outputDevices = outs
        inputDevices = ins
        defaultInputDeviceName = ins.first(where: \.isSelected)?.name

        guard currentOutID != kAudioObjectUnknown else { return }

        if let activeOut = outs.first(where: { $0.id == currentOutID }) {
            outputDeviceName = activeOut.name
            outputTransportLabel = activeOut.transportLabel
            outputSymbolName = activeOut.symbolName
            outputSampleRateHz = activeOut.sampleRateHz
            outputChannelCount = activeOut.channelCount
        } else if let name = Self.readDeviceName(currentOutID) {
            let t = Self.readTransportType(currentOutID)
            outputDeviceName = name
            outputTransportLabel = Self.transportLabel(for: t, name: name)
            outputSymbolName = Self.outputSymbol(for: t, name: name)
            outputSampleRateHz = Self.readNominalSampleRate(currentOutID)
            outputChannelCount = max(1, Self.channelCount(for: currentOutID, scope: kAudioDevicePropertyScopeOutput))
        }

        var vol: Float32 = volume
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(currentOutID, &volAddr, 0, nil, &volSize, &vol) == noErr {
            volume = min(1.0, max(0.0, vol))
        }

        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(currentOutID, &muteAddr, 0, nil, &muteSize, &muted) == noErr {
            isMuted = (muted != 0)
        } else if softMutedRestoreVolume != nil && volume <= 0.005 {
            isMuted = true
        } else {
            isMuted = false
        }
    }

    func selectOutputDevice(_ targetID: AudioDeviceID) {
        guard targetID != kAudioObjectUnknown else { return }
        var id = targetID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(systemObj, &defaultOutAddr, 0, nil, size, &id)

        // Also update system/alert output device to match macOS Control Center behavior
        var sysOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(systemObj, &sysOutAddr, 0, nil, size, &id)

        if status == noErr {
            refresh()
        }
    }

    func selectInputDevice(_ targetID: AudioDeviceID) {
        guard targetID != kAudioObjectUnknown else { return }
        var id = targetID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInAddr,
            0,
            nil,
            size,
            &id
        ) == noErr {
            refresh()
        }
    }

    func setVolume(_ newVolume: Float) {
        let deviceID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown else { return }

        var clamped = Float32(min(1.0, max(0.0, newVolume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if isMuted && clamped > 0.01 {
            softMutedRestoreVolume = nil
            _ = Self.setHardwareMute(deviceID, muted: false)
            isMuted = false
        }

        if AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, size, &clamped) == noErr {
            volume = clamped
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        let deviceID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown else { return }

        if Self.setHardwareMute(deviceID, muted: muted) {
            isMuted = muted
            return
        }

        // Soft-mute fallback for Bluetooth headsets that do not expose hardware kAudioDevicePropertyMute
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<Float32>.size)
        if muted {
            softMutedRestoreVolume = volume > 0.02 ? volume : 0.35
            var zero: Float32 = 0.0
            if AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, size, &zero) == noErr {
                volume = 0.0
                isMuted = true
            }
        } else {
            var restore = Float32(softMutedRestoreVolume ?? 0.35)
            softMutedRestoreVolume = nil
            if AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, size, &restore) == noErr {
                volume = restore
                isMuted = false
            }
        }
    }

    // MARK: - CoreAudio Helpers

    private static func setHardwareMute(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var flag: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &muteAddr),
              AudioObjectIsPropertySettable(deviceID, &muteAddr, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        return AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &flag) == noErr
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(sysObj, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.filter { $0 != kAudioObjectUnknown }
    }

    private static func canBeDefaultDevice(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return true }
        var canBeDefault: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &canBeDefault) == noErr {
            return canBeDefault != 0
        }
        return true
    }

    private static func isHiddenDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &hidden) == noErr, hidden != 0 {
            return true
        }
        if let name = readDeviceName(deviceID), name.hasPrefix("CADefaultDeviceAggregate") {
            return true
        }
        return false
    }

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPtr) == noErr else {
            return 0
        }
        let ablPtr = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        var total = 0
        for buf in buffers {
            total += Int(buf.mNumberChannels)
        }
        return total
    }

    private static func readDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let str = cfName?.takeRetainedValue() as String?, !str.isEmpty else {
            return nil
        }
        return str
    }

    private static func readTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr {
            return transport
        }
        return 0
    }

    private static func readNominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr, rate > 0 {
            return rate
        }
        return nil
    }

    private static func transportLabel(for transport: UInt32, name: String) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeAirPlay:
            return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypeAggregate:
            return "Multi-Output"
        default:
            let lower = name.lowercased()
            if lower.contains("airpods") || lower.contains("bluetooth") { return "Bluetooth" }
            if lower.contains("macbook") || lower.contains("built-in") { return "Built-in" }
            return "Audio"
        }
    }

    private static func outputSymbol(for transport: UInt32, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") || lower.contains("headphone") || lower.contains("headset") || lower.contains("buds") {
            return "headphones"
        }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return "hifispeaker.fill"
        }
    }

    private static func inputSymbol(for transport: UInt32, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return "headphones"
        }
        return "mic.fill"
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }
}
