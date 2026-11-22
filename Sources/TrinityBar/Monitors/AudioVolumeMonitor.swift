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
    /// Device topology / default-device changes -> full device enumeration.
    nonisolated(unsafe) private var systemListenerBlock: AudioObjectPropertyListenerBlock?
    /// Volume / mute changes on the active output -> lightweight scalar refresh only.
    nonisolated(unsafe) private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var softMutedRestoreVolume: Float?

    nonisolated private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDevices
    ]

    nonisolated private static let outputDeviceSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyMute
    ]

    init() {
        refresh()
        observeSystemAudioChanges()
    }

    deinit {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        if let block = systemListenerBlock {
            for selector in Self.systemSelectors {
                var addr = Self.propertyAddress(selector)
                AudioObjectRemovePropertyListenerBlock(systemObj, &addr, DispatchQueue.main, block)
            }
        }
        if let block = deviceListenerBlock, observedDeviceID != kAudioObjectUnknown {
            for selector in Self.outputDeviceSelectors {
                var addr = Self.propertyAddress(selector, scope: kAudioDevicePropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(observedDeviceID, &addr, DispatchQueue.main, block)
            }
        }
    }

    private func observeSystemAudioChanges() {
        let systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshVolumeAndMute()
            }
        }
        systemListenerBlock = systemBlock
        deviceListenerBlock = deviceBlock

        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        for selector in Self.systemSelectors {
            var addr = Self.propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(systemObj, &addr, DispatchQueue.main, systemBlock)
        }
        attachDeviceListenersIfNeeded()
    }

    private func attachDeviceListenersIfNeeded() {
        guard let block = deviceListenerBlock else { return }
        let deviceID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown, deviceID != observedDeviceID else { return }

        if observedDeviceID != kAudioObjectUnknown {
            for selector in Self.outputDeviceSelectors {
                var addr = Self.propertyAddress(selector, scope: kAudioDevicePropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(observedDeviceID, &addr, DispatchQueue.main, block)
            }
        }

        observedDeviceID = deviceID
        softMutedRestoreVolume = nil

        for selector in Self.outputDeviceSelectors {
            var addr = Self.propertyAddress(selector, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block)
        }
    }

    /// Full refresh: re-enumerates every audio device plus the active output's volume / mute state.
    func refresh() {
        attachDeviceListenersIfNeeded()

        let currentOutID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let currentInID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)

        let allIDs = Self.allAudioDeviceIDs()
        var outs: [AudioDeviceItem] = []
        var ins: [AudioDeviceItem] = []

        for id in allIDs {
            guard let name = Self.readDeviceName(id), !Self.isHiddenDevice(id, name: name) else { continue }
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

        if outputDevices != outs { outputDevices = outs }
        if inputDevices != ins { inputDevices = ins }
        let newDefaultInput = ins.first(where: \.isSelected)?.name
        if defaultInputDeviceName != newDefaultInput { defaultInputDeviceName = newDefaultInput }

        guard currentOutID != kAudioObjectUnknown else { return }

        if let activeOut = outs.first(where: { $0.id == currentOutID }) {
            if outputDeviceName != activeOut.name { outputDeviceName = activeOut.name }
            if outputTransportLabel != activeOut.transportLabel { outputTransportLabel = activeOut.transportLabel }
            if outputSymbolName != activeOut.symbolName { outputSymbolName = activeOut.symbolName }
            if outputSampleRateHz != activeOut.sampleRateHz { outputSampleRateHz = activeOut.sampleRateHz }
            if outputChannelCount != activeOut.channelCount { outputChannelCount = activeOut.channelCount }
        } else if let name = Self.readDeviceName(currentOutID) {
            let t = Self.readTransportType(currentOutID)
            let tr = Self.transportLabel(for: t, name: name)
            let sym = Self.outputSymbol(for: t, name: name)
            let sr = Self.readNominalSampleRate(currentOutID)
            let ch = max(1, Self.channelCount(for: currentOutID, scope: kAudioDevicePropertyScopeOutput))
            if outputDeviceName != name { outputDeviceName = name }
            if outputTransportLabel != tr { outputTransportLabel = tr }
            if outputSymbolName != sym { outputSymbolName = sym }
            if outputSampleRateHz != sr { outputSampleRateHz = sr }
            if outputChannelCount != ch { outputChannelCount = ch }
        }

        refreshVolumeAndMute(deviceID: currentOutID)
    }

    /// Lightweight refresh of only the active output's volume and mute scalars (fired on every volume tick).
    private func refreshVolumeAndMute(deviceID: AudioDeviceID? = nil) {
        let currentOutID = deviceID ?? Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard currentOutID != kAudioObjectUnknown else { return }

        if let vol: Float32 = Self.readScalar(
            currentOutID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            initial: volume
        ) {
            let clamped = min(1.0, max(0.0, vol))
            if abs(volume - clamped) > 0.0001 { volume = clamped }
        }

        let hardwareMuteSupported = Self.isHardwareMuteSettable(currentOutID)
        let newMuted: Bool
        if let muted: UInt32 = Self.readScalar(
            currentOutID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            initial: 0
        ), (hardwareMuteSupported || muted != 0) {
            newMuted = (muted != 0)
            if !newMuted {
                softMutedRestoreVolume = nil
            }
        } else if softMutedRestoreVolume != nil && volume <= 0.005 {
            newMuted = true
        } else {
            softMutedRestoreVolume = nil
            newMuted = false
        }
        if isMuted != newMuted { isMuted = newMuted }
    }

    func selectOutputDevice(_ targetID: AudioDeviceID) {
        guard targetID != kAudioObjectUnknown else { return }
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        let ok = Self.writeScalar(systemObj, selector: kAudioHardwarePropertyDefaultOutputDevice, value: targetID)
        // Also update system/alert output device to match macOS Control Center behavior
        _ = Self.writeScalar(systemObj, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, value: targetID)
        if ok { refresh() }
    }

    func selectInputDevice(_ targetID: AudioDeviceID) {
        guard targetID != kAudioObjectUnknown else { return }
        if Self.writeScalar(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            value: targetID
        ) {
            refresh()
        }
    }

    func setVolume(_ newVolume: Float) {
        let deviceID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown else { return }

        let clamped = Float32(min(1.0, max(0.0, newVolume)))
        let shouldUnmute = isMuted && clamped > 0.005
        if !shouldUnmute && abs(clamped - volume) < 0.0001 {
            return
        }

        if shouldUnmute {
            softMutedRestoreVolume = nil
            _ = Self.setHardwareMute(deviceID, muted: false)
            isMuted = false
        }

        if Self.writeScalar(
            deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            value: clamped
        ) {
            volume = clamped
        }
    }

    /// Relative volume step used by scroll gestures; never lowers volume while muted.
    func adjustVolume(by delta: Float) {
        if isMuted && delta < 0 { return }
        setVolume(volume + delta)
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

        // Soft-mute fallback for Bluetooth headsets that do not expose settable hardware mute
        if muted {
            softMutedRestoreVolume = volume > 0.02 ? volume : 0.35
            if Self.writeScalar(
                deviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput,
                value: Float32(0.0)
            ) {
                volume = 0.0
                isMuted = true
            }
        } else {
            let restore = Float32(softMutedRestoreVolume ?? 0.35)
            softMutedRestoreVolume = nil
            if Self.writeScalar(
                deviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput,
                value: restore
            ) {
                volume = restore
                isMuted = false
            }
        }
    }

    // MARK: - CoreAudio Helpers

    nonisolated private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readScalar<T: BitwiseCopyable>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        var address = propertyAddress(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { buf -> OSStatus in
            guard let base = buf.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, base)
        }
        return status == noErr ? value : nil
    }

    private static func writeScalar<T: BitwiseCopyable>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: T
    ) -> Bool {
        var address = propertyAddress(selector, scope: scope)
        var mutableValue = value
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeBytes(of: &mutableValue) { buf -> OSStatus in
            guard let base = buf.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectSetPropertyData(objectID, &address, 0, nil, size, base)
        } == noErr
    }

    private static func isHardwareMuteSettable(_ deviceID: AudioDeviceID) -> Bool {
        var muteAddr = propertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(deviceID, &muteAddr)
            && AudioObjectIsPropertySettable(deviceID, &muteAddr, &settable) == noErr
            && settable.boolValue
    }

    private static func setHardwareMute(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        guard isHardwareMuteSettable(deviceID) else { return false }
        return writeScalar(
            deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            value: UInt32(muted ? 1 : 0)
        )
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
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
        var address = propertyAddress(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope)
        guard AudioObjectHasProperty(deviceID, &address) else { return true }
        if let canBeDefault: UInt32 = readScalar(deviceID, selector: kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope, initial: 1) {
            return canBeDefault != 0
        }
        return true
    }

    private static func isHiddenDevice(_ deviceID: AudioDeviceID, name: String) -> Bool {
        if name.hasPrefix("CADefaultDeviceAggregate") { return true }
        if let hidden: UInt32 = readScalar(deviceID, selector: kAudioDevicePropertyIsHidden, initial: 0), hidden != 0 {
            return true
        }
        return false
    }

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
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
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func readDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = propertyAddress(kAudioObjectPropertyName)
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let str = cfName?.takeRetainedValue() as String?, !str.isEmpty else {
            return nil
        }
        return str
    }

    private static func readTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        readScalar(deviceID, selector: kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
    }

    private static func readNominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        guard let rate: Float64 = readScalar(deviceID, selector: kAudioDevicePropertyNominalSampleRate, initial: 0),
              rate > 0 else {
            return nil
        }
        return rate
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        readScalar(
            AudioObjectID(kAudioObjectSystemObject),
            selector: selector,
            initial: AudioDeviceID(kAudioObjectUnknown)
        ) ?? kAudioObjectUnknown
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
}
