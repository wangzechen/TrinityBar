import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

struct EnergyAppItem: Identifiable, Equatable {
    let id: String // bundlePath
    let name: String
    let icon: NSImage?
    let powerText: String
    let score: Double

    static func == (lhs: EnergyAppItem, rhs: EnergyAppItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.powerText == rhs.powerText
    }
}

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var hasBattery: Bool = true
    @Published private(set) var percentage: Int = 100
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isLowPowerMode: Bool = false
    @Published private(set) var timeRemainingMinutes: Int?
    @Published private(set) var wattage: Double? // signed (+charging, -discharging)
    @Published private(set) var healthPercent: Int?
    @Published private(set) var cycleCount: Int?

    // Second-layer rich telemetry (AppleSMC + AppleSmartBattery + IOPS Adapter)
    @Published private(set) var adapterRatedWatts: Int?
    @Published private(set) var adapterInputWatts: Double?
    @Published private(set) var systemLoadWatts: Double?
    @Published private(set) var displayWatts: Double?
    @Published private(set) var usbOutputWatts: Double?
    @Published private(set) var temperatureCelsius: Double?
    @Published private(set) var voltageVolts: Double?
    @Published private(set) var amperageMA: Int?
    @Published private(set) var designCapacityMAh: Int?
    @Published private(set) var maxCapacityMAh: Int?
    @Published private(set) var conditionText: String = "Normal"
    @Published private(set) var highEnergyApps: [EnergyAppItem] = []
    @Published private(set) var isSamplingEnergyApps: Bool = false

    private struct RawAppCounter: Sendable {
        let cpuNs: UInt64
        let energyNj: UInt64
    }

    private struct SMCSensorSnapshot: Sendable {
        let systemLoadWatts: Double?
        let adapterInputWatts: Double?
        let displayWatts: Double?
        let usbOutputWatts: Double?
        let batteryVoltageVolts: Double?
        let batteryAmperageMA: Int?
        let batteryWattage: Double?
    }

    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var powerStateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var refreshTimer: Timer?
    nonisolated(unsafe) private var popoverTimer: Timer?
    nonisolated(unsafe) private var smcTask: Task<Void, Never>?
    nonisolated(unsafe) private var energyAppsTask: Task<Void, Never>?
    private var isPopoverVisible: Bool = false
    private var smcGeneration: UInt64 = 0
    private var energySampleGeneration: UInt64 = 0
    private var lastAppSampleTime: TimeInterval?
    private var lastAppCounters: [String: RawAppCounter] = [:]

    init() {
        refresh()
        setupNotifications()
    }

    deinit {
        smcTask?.cancel()
        energyAppsTask?.cancel()
        popoverTimer?.invalidate()
        refreshTimer?.invalidate()
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        popoverTimer?.invalidate()
        popoverTimer = nil

        guard visible else {
            smcGeneration &+= 1
            energySampleGeneration &+= 1
            smcTask?.cancel()
            smcTask = nil
            energyAppsTask?.cancel()
            energyAppsTask = nil
            lastAppSampleTime = nil
            lastAppCounters.removeAll()
            highEnergyApps = []
            isSamplingEnergyApps = false
            return
        }

        refresh(includeDetailedSensors: true)
        sampleEnergyApps()

        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh(includeDetailedSensors: true)
                self.sampleEnergyApps()
            }
        }
        timer.tolerance = 0.25
        popoverTimer = timer
    }

    private func setupNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
                monitor.refresh()
            }
        }

        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.runLoopSource = source
        }

        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }

        let bgTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        bgTimer.tolerance = 5.0
        refreshTimer = bgTimer
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<BatteryMonitor, T>, to value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    func refresh(includeDetailedSensors: Bool = false) {
        setIfChanged(\.isLowPowerMode, to: ProcessInfo.processInfo.isLowPowerModeEnabled)

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let rated = adapter[kIOPSPowerAdapterWattsKey as String] as? Int, rated > 0 {
            setIfChanged(\.adapterRatedWatts, to: rated)
        } else {
            setIfChanged(\.adapterRatedWatts, to: nil)
        }

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any]
        else {
            setIfChanged(\.hasBattery, to: false)
            setIfChanged(\.percentage, to: 100)
            setIfChanged(\.isCharging, to: false)
            setIfChanged(\.isPluggedIn, to: true)
            setIfChanged(\.timeRemainingMinutes, to: nil)
            setIfChanged(\.wattage, to: nil)
            setIfChanged(\.healthPercent, to: nil)
            setIfChanged(\.cycleCount, to: nil)
            setIfChanged(\.temperatureCelsius, to: nil)
            setIfChanged(\.voltageVolts, to: nil)
            setIfChanged(\.amperageMA, to: nil)
            setIfChanged(\.designCapacityMAh, to: nil)
            setIfChanged(\.maxCapacityMAh, to: nil)
            if includeDetailedSensors || popoverTimer != nil {
                readSMCSensors()
            }
            return
        }

        setIfChanged(\.hasBattery, to: true)
        let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
        let maxCap = max(1, desc[kIOPSMaxCapacityKey as String] as? Int ?? 100)
        setIfChanged(\.percentage, to: min(100, max(0, Int(round(Double(current) / Double(maxCap) * 100.0)))))

        let powerState = desc[kIOPSPowerSourceStateKey as String] as? String
        setIfChanged(\.isPluggedIn, to: powerState == kIOPSACPowerValue as String)
        let charging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
        setIfChanged(\.isCharging, to: charging)

        let nextMinutes: Int?
        if charging {
            if let ttf = desc[kIOPSTimeToFullChargeKey as String] as? Int, ttf > 0, ttf < 6000 {
                nextMinutes = ttf
            } else {
                nextMinutes = nil
            }
        } else {
            if let tte = desc[kIOPSTimeToEmptyKey as String] as? Int, tte > 0, tte < 6000 {
                nextMinutes = tte
            } else {
                nextMinutes = nil
            }
        }
        setIfChanged(\.timeRemainingMinutes, to: nextMinutes)

        readSmartBatteryRegistry()
        if includeDetailedSensors || popoverTimer != nil {
            readSMCSensors()
        }
    }

    private func readSmartBatteryRegistry() {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any]
        else { return }

        if let cycles = props["CycleCount"] as? Int, cycles >= 0 {
            setIfChanged(\.cycleCount, to: cycles)
        }

        let rawMax = (props["AppleRawMaxCapacity"] as? Int) ?? (props["NominalChargeCapacity"] as? Int)
        let design = props["DesignCapacity"] as? Int
        if let rawMax, rawMax > 200 { setIfChanged(\.maxCapacityMAh, to: rawMax) }
        if let design, design > 200 { setIfChanged(\.designCapacityMAh, to: design) }

        if let directHealth = props["MaximumCapacityPercent"] as? Int, (10...110).contains(directHealth) {
            setIfChanged(\.healthPercent, to: min(100, directHealth))
        } else if let rawMax, let design, rawMax > 200, design > 200 {
            let pct = Int(round(Double(rawMax) / Double(design) * 100.0))
            if (10...110).contains(pct) {
                setIfChanged(\.healthPercent, to: min(100, pct))
            }
        }

        if let pf = props["PermanentFailureStatus"] as? Int, pf != 0 {
            setIfChanged(\.conditionText, to: "Service Recommended")
        } else {
            setIfChanged(\.conditionText, to: "Normal")
        }

        // Temperature in AppleSmartBattery is reported in centi-Celsius (~3120 -> 31.2°C) or deci-Kelvin (~3045 -> 31.35°C).
        if let rawTemp = props["Temperature"] as? Int, rawTemp > 0 {
            let cFromDeciKelvin = Double(rawTemp) / 10.0 - 273.15
            let cFromCentiCelsius = Double(rawTemp) / 100.0
            if (5.0...85.0).contains(cFromCentiCelsius) {
                setIfChanged(\.temperatureCelsius, to: cFromCentiCelsius)
            } else if (5.0...85.0).contains(cFromDeciKelvin) {
                setIfChanged(\.temperatureCelsius, to: cFromDeciKelvin)
            }
        }

        if let mv = props["Voltage"] as? Int, mv > 1_000 {
            setIfChanged(\.voltageVolts, to: Double(mv) / 1000.0)
            if let rawAmp = props["InstantAmperage"] as? Int, abs(rawAmp) < 30_000 {
                setIfChanged(\.amperageMA, to: rawAmp)
                setIfChanged(\.wattage, to: (Double(mv) * Double(rawAmp)) / 1_000_000.0)
            }
        }
    }

    // MARK: - Read-Only AppleSMC Power Sensors

    private func readSMCSensors() {
        smcTask?.cancel()
        smcGeneration &+= 1
        let generation = smcGeneration
        let pluggedIn = isPluggedIn
        smcTask = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.readSMCSensorsSnapshot(isPluggedIn: pluggedIn)
            }.value
            guard let self, self.smcGeneration == generation else { return }
            self.smcTask = nil
            guard !Task.isCancelled, let snapshot else { return }
            self.applySMCSnapshot(snapshot)
        }
    }

    private func applySMCSnapshot(_ snapshot: SMCSensorSnapshot) {
        if let pstr = snapshot.systemLoadWatts, systemLoadWatts != pstr {
            systemLoadWatts = pstr
        }
        let nextAdapter = isPluggedIn ? snapshot.adapterInputWatts : nil
        if adapterInputWatts != nextAdapter { adapterInputWatts = nextAdapter }
        if displayWatts != snapshot.displayWatts { displayWatts = snapshot.displayWatts }
        if usbOutputWatts != snapshot.usbOutputWatts { usbOutputWatts = snapshot.usbOutputWatts }

        if hasBattery,
           let bv = snapshot.batteryVoltageVolts,
           let ba = snapshot.batteryAmperageMA,
           let w = snapshot.batteryWattage {
            if voltageVolts != bv { voltageVolts = bv }
            if amperageMA != ba { amperageMA = ba }
            if wattage != w { wattage = w }
        }
    }

    nonisolated private static func readSMCSensorsSnapshot(isPluggedIn: Bool) -> SMCSensorSnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(conn) }

        let exchange: ([UInt8]) -> [UInt8]? = { req in
            var resp = [UInt8](repeating: 0, count: 80)
            var size = resp.count
            let kr = req.withUnsafeBytes { inBuf in
                resp.withUnsafeMutableBytes { outBuf in
                    IOConnectCallStructMethod(conn, 2, inBuf.baseAddress, inBuf.count, outBuf.baseAddress, &size)
                }
            }
            return (kr == KERN_SUCCESS && size == 80) ? resp : nil
        }

        let pstrVal: Double?
        if let pstr = readSMCScalar(key: 0x50535452, exchange: exchange), pstr > 0, pstr <= 500 {
            pstrVal = pstr
        } else {
            pstrVal = nil
        }

        let pdtrVal: Double?
        if isPluggedIn, let pdtr = readSMCScalar(key: 0x50445452, exchange: exchange), pdtr >= 0, pdtr <= 500 {
            pdtrVal = pdtr
        } else {
            pdtrVal = nil
        }

        let dispVal: Double?
        if let pdbr = readSMCScalar(key: 0x50444252, exchange: exchange), pdbr >= 0, pdbr <= 120 {
            dispVal = pdbr
        } else if let pblr = readSMCScalar(key: 0x50424C52, exchange: exchange), pblr >= 0, pblr <= 120 {
            dispVal = pblr
        } else {
            dispVal = nil
        }

        var portTotal: Double = 0
        var portFound = false
        for ch in 1...4 {
            let vKey = (UInt32(0x44) << 24) | (UInt32(0x30 + ch) << 16) | 0x4A56 // DnJV
            let iKey = (UInt32(0x44) << 24) | (UInt32(0x30 + ch) << 16) | 0x4A49 // DnJI
            if let v = readSMCScalar(key: vKey, exchange: exchange),
               let a = readSMCScalar(key: iKey, exchange: exchange) {
                let w = v * a
                if w.isFinite, w > 0.05, w <= 150 {
                    portTotal += w
                    portFound = true
                }
            }
        }

        var bvOut: Double?
        var baOut: Int?
        var wOut: Double?
        if let bv = readSMCIntegerSensor(key: 0x42304156, signed: false, exchange: exchange),
           let ba = readSMCIntegerSensor(key: 0x42304143, signed: true, exchange: exchange),
           (3.0...25.0).contains(bv), abs(ba) <= 25.0 {
            bvOut = bv
            baOut = Int(round(ba * 1000.0))
            wOut = bv * ba
        }

        return SMCSensorSnapshot(
            systemLoadWatts: pstrVal,
            adapterInputWatts: pdtrVal,
            displayWatts: dispVal,
            usbOutputWatts: portFound ? portTotal : nil,
            batteryVoltageVolts: bvOut,
            batteryAmperageMA: baOut,
            batteryWattage: wOut
        )
    }

    nonisolated private static func leUInt32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }

    nonisolated private static func readSMCRaw(
        key: UInt32,
        exchange: ([UInt8]) -> [UInt8]?
    ) -> (type: UInt32, size: UInt32, resp: [UInt8])? {
        var req = [UInt8](repeating: 0, count: 80)
        for i in 0..<4 { req[i] = UInt8(truncatingIfNeeded: key >> (i * 8)) }
        req[42] = 9 // read key info
        guard let info = exchange(req), info[40] == 0 else { return nil }
        let size = leUInt32(info, 28)
        let type = leUInt32(info, 32)
        req.replaceSubrange(28..<32, with: info[28..<32])
        req[42] = 5 // read bytes
        guard let resp = exchange(req), resp[40] == 0 else { return nil }
        return (type, size, resp)
    }

    nonisolated private static func readSMCScalar(key: UInt32, exchange: ([UInt8]) -> [UInt8]?) -> Double? {
        guard let raw = readSMCRaw(key: key, exchange: exchange) else { return nil }
        let val: Double
        switch (raw.type, raw.size) {
        case (0x666c7420, 4):
            val = Double(Float(bitPattern: leUInt32(raw.resp, 48)))
        case (0x66706532, 2):
            let bits = (UInt16(raw.resp[48]) << 8) | UInt16(raw.resp[49])
            val = Double(bits) / 4.0
        case (0x73703738, 2):
            let bits = (UInt16(raw.resp[48]) << 8) | UInt16(raw.resp[49])
            val = Double(Int16(bitPattern: bits)) / 256.0
        default:
            return nil
        }
        return val.isFinite ? val : nil
    }

    nonisolated private static func readSMCIntegerSensor(key: UInt32, signed: Bool, exchange: ([UInt8]) -> [UInt8]?) -> Double? {
        guard let raw = readSMCRaw(key: key, exchange: exchange),
              raw.size == 2,
              (raw.type == 0x73693136 || raw.type == 0x75693136) else {
            return nil
        }
        let bits = UInt16(raw.resp[48]) | (UInt16(raw.resp[49]) << 8)
        let val = (signed ? Double(Int16(bitPattern: bits)) : Double(bits)) / 1000.0
        return val.isFinite ? val : nil
    }

    // MARK: - High Energy Apps Sampling (proc_pid_rusage RUSAGE_INFO_V6)

    private func sampleEnergyApps() {
        guard energyAppsTask == nil else { return }

        let myBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        var appLookup: [String: (name: String, icon: NSImage?)] = [:]
        var appPaths: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory,
                  let url = app.bundleURL else { continue }
            let path = url.standardizedFileURL.path
            guard path != myBundlePath, path.hasSuffix(".app") else { continue }
            // Exclude headless macOS system agents (e.g. MenuBarAgent, ControlCenter, WindowManager)
            // while preserving user-facing regular apps (including Finder / System Settings).
            if app.activationPolicy != .regular && path.hasPrefix("/System/Library/") {
                continue
            }
            if appLookup[path] == nil {
                let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
                appLookup[path] = (name, app.icon)
                appPaths.append(path)
            }
        }
        guard !appPaths.isEmpty else { return }

        if lastAppSampleTime == nil {
            isSamplingEnergyApps = true
        }

        // Sort shortest-first so the first prefix match is always the outer .app bundle
        let sortedPaths = appPaths.sorted { $0.count < $1.count }
        energySampleGeneration &+= 1
        let generation = energySampleGeneration

        energyAppsTask = Task { @MainActor [weak self] in
            let sample = await Task.detached(priority: .utility) {
                Self.collectAppCounters(sortedAppPaths: sortedPaths)
            }.value
            guard let self, self.energySampleGeneration == generation else { return }
            self.energyAppsTask = nil
            guard !Task.isCancelled, self.isPopoverVisible, let sample else { return }

            let (currentCounters, now) = sample
            if let prevTime = self.lastAppSampleTime {
                let dt = max(0.4, now - prevTime)
                var items: [EnergyAppItem] = []

                for (path, cur) in currentCounters {
                    guard let prev = self.lastAppCounters[path], let info = appLookup[path] else { continue }
                    let dEnergy = cur.energyNj >= prev.energyNj ? Double(cur.energyNj - prev.energyNj) : 0
                    let dCpu = cur.cpuNs >= prev.cpuNs ? Double(cur.cpuNs - prev.cpuNs) : 0

                    if dEnergy > 0 {
                        let watts = (dEnergy / 1_000_000_000.0) / dt
                        if watts >= 0.05 {
                            items.append(EnergyAppItem(
                                id: path,
                                name: info.name,
                                icon: info.icon,
                                powerText: String(format: "%.2f W", watts),
                                score: watts * 100.0
                            ))
                        }
                    } else if dCpu > 0 {
                        let cpuPct = (dCpu / 1_000_000_000.0) / dt * 100.0
                        if cpuPct >= 0.5 {
                            items.append(EnergyAppItem(
                                id: path,
                                name: info.name,
                                icon: info.icon,
                                powerText: String(format: "%.1f%% CPU", cpuPct),
                                score: cpuPct
                            ))
                        }
                    }
                }
                items.sort { $0.score > $1.score }
                let topItems = Array(items.prefix(5))
                if self.highEnergyApps != topItems {
                    self.highEnergyApps = topItems
                }
                if self.isSamplingEnergyApps {
                    self.isSamplingEnergyApps = false
                }
            }

            self.lastAppCounters = currentCounters
            self.lastAppSampleTime = now
        }
    }

    nonisolated private static let machTimebaseNanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom > 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }()

    nonisolated private static func collectAppCounters(
        sortedAppPaths: [String]
    ) -> (counters: [String: RawAppCounter], timestamp: TimeInterval)? {
        let now = ProcessInfo.processInfo.systemUptime
        let byteCount = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard byteCount > 0 else { return nil }
        let cap = min(Int(byteCount) / MemoryLayout<pid_t>.stride + 64, 8192)
        var pids = [pid_t](repeating: 0, count: cap)
        let returned = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard returned > 0 else { return nil }
        let pidCount = max(0, min(Int(returned) / MemoryLayout<pid_t>.stride, cap))

        let pathPrefixes = sortedAppPaths.map { (path: $0, prefix: $0 + "/") }
        let nsPerTick = machTimebaseNanosPerTick
        var currentCounters: [String: RawAppCounter] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(pidCount) where pid > 0 {
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let execPath = String(decoding: pathBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let matchedPath = pathPrefixes.first(where: { execPath.hasPrefix($0.prefix) })?.path else {
                continue
            }

            var usage = rusage_info_v6()
            let kr = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard kr == 0 else { continue }
            let cpuTicks = usage.ri_user_time &+ usage.ri_system_time
            let cpuNs = UInt64(Double(cpuTicks) * nsPerTick)
            let energy = usage.ri_energy_nj
            let prev = currentCounters[matchedPath] ?? RawAppCounter(cpuNs: 0, energyNj: 0)
            currentCounters[matchedPath] = RawAppCounter(
                cpuNs: prev.cpuNs &+ cpuNs,
                energyNj: prev.energyNj &+ energy
            )
        }

        return (currentCounters, now)
    }
}
