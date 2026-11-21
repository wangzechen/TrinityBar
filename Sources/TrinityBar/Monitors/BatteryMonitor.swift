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

    private struct RawAppCounter {
        let cpuNs: UInt64
        let energyNj: UInt64
    }

    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var powerStateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var refreshTimer: Timer?
    nonisolated(unsafe) private var popoverTimer: Timer?
    private var lastAppSampleTime: TimeInterval?
    private var lastAppCounters: [String: RawAppCounter] = [:]

    init() {
        refresh()
        setupNotifications()
    }

    deinit {
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
        popoverTimer?.invalidate()
        popoverTimer = nil

        guard visible else {
            lastAppSampleTime = nil
            lastAppCounters.removeAll()
            return
        }

        refresh(includeDetailedSensors: true)
        sampleEnergyApps()

        popoverTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh(includeDetailedSensors: true)
                self.sampleEnergyApps()
            }
        }
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

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh(includeDetailedSensors: Bool = false) {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let rated = adapter[kIOPSPowerAdapterWattsKey as String] as? Int, rated > 0 {
            adapterRatedWatts = rated
        } else {
            adapterRatedWatts = nil
        }

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any]
        else {
            hasBattery = false
            percentage = 100
            isCharging = false
            isPluggedIn = true
            if includeDetailedSensors || popoverTimer != nil {
                readSMCSensors()
            }
            return
        }

        hasBattery = true
        let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
        let maxCap = max(1, desc[kIOPSMaxCapacityKey as String] as? Int ?? 100)
        percentage = min(100, max(0, Int(round(Double(current) / Double(maxCap) * 100.0))))

        let powerState = desc[kIOPSPowerSourceStateKey as String] as? String
        isPluggedIn = (powerState == kIOPSACPowerValue as String)
        isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false

        if isCharging {
            if let ttf = desc[kIOPSTimeToFullChargeKey as String] as? Int, ttf > 0, ttf < 6000 {
                timeRemainingMinutes = ttf
            } else {
                timeRemainingMinutes = nil
            }
        } else {
            if let tte = desc[kIOPSTimeToEmptyKey as String] as? Int, tte > 0, tte < 6000 {
                timeRemainingMinutes = tte
            } else {
                timeRemainingMinutes = nil
            }
        }

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
            cycleCount = cycles
        }

        let rawMax = (props["AppleRawMaxCapacity"] as? Int) ?? (props["NominalChargeCapacity"] as? Int)
        let design = props["DesignCapacity"] as? Int
        if let rawMax, rawMax > 200 { maxCapacityMAh = rawMax }
        if let design, design > 200 { designCapacityMAh = design }

        if let directHealth = props["MaximumCapacityPercent"] as? Int, (10...110).contains(directHealth) {
            healthPercent = min(100, directHealth)
        } else if let rawMax, let design, rawMax > 200, design > 200 {
            let pct = Int(round(Double(rawMax) / Double(design) * 100.0))
            if (10...110).contains(pct) {
                healthPercent = min(100, pct)
            }
        }

        if let pf = props["PermanentFailureStatus"] as? Int, pf != 0 {
            conditionText = "Service Recommended"
        } else {
            conditionText = "Normal"
        }

        // Temperature in AppleSmartBattery is reported in centi-Kelvin or centi-Celsius depending on platform:
        // On Apple Silicon macOS, "Temperature" is typically deci-Kelvin (e.g. 3045 -> 304.5K -> 31.35°C) or centi-Celsius (~3120 -> 31.2°C).
        if let rawTemp = props["Temperature"] as? Int, rawTemp > 0 {
            let cFromDeciKelvin = Double(rawTemp) / 10.0 - 273.15
            let cFromCentiCelsius = Double(rawTemp) / 100.0
            if (5.0...85.0).contains(cFromCentiCelsius) {
                temperatureCelsius = cFromCentiCelsius
            } else if (5.0...85.0).contains(cFromDeciKelvin) {
                temperatureCelsius = cFromDeciKelvin
            }
        }

        if let mv = props["Voltage"] as? Int, mv > 1_000 {
            voltageVolts = Double(mv) / 1000.0
            if let rawAmp = props["InstantAmperage"] as? Int {
                let signedAmp = Int(Int64(bitPattern: UInt64(bitPattern: Int64(rawAmp))))
                if abs(signedAmp) < 30_000 {
                    amperageMA = signedAmp
                    wattage = (Double(mv) * Double(signedAmp)) / 1_000_000.0
                }
            }
        }
    }

    // MARK: - Read-Only AppleSMC Power Sensors

    private func readSMCSensors() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return }
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

        if let pstr = Self.readSMCScalar(key: 0x50535452, exchange: exchange), pstr > 0, pstr <= 500 {
            systemLoadWatts = pstr
        }
        if isPluggedIn, let pdtr = Self.readSMCScalar(key: 0x50445452, exchange: exchange), pdtr >= 0, pdtr <= 500 {
            adapterInputWatts = pdtr
        } else {
            adapterInputWatts = nil
        }

        if let pdbr = Self.readSMCScalar(key: 0x50444252, exchange: exchange), pdbr >= 0, pdbr <= 120 {
            displayWatts = pdbr
        } else if let pblr = Self.readSMCScalar(key: 0x50424C52, exchange: exchange), pblr >= 0, pblr <= 120 {
            displayWatts = pblr
        } else {
            displayWatts = nil
        }

        var portTotal: Double = 0
        var portFound = false
        for ch in 1...4 {
            let vKey = (UInt32(0x44) << 24) | (UInt32(0x30 + ch) << 16) | 0x4A56 // DnJV
            let iKey = (UInt32(0x44) << 24) | (UInt32(0x30 + ch) << 16) | 0x4A49 // DnJI
            if let v = Self.readSMCScalar(key: vKey, exchange: exchange),
               let a = Self.readSMCScalar(key: iKey, exchange: exchange) {
                let w = v * a
                if w.isFinite, w > 0.05, w <= 150 {
                    portTotal += w
                    portFound = true
                }
            }
        }
        usbOutputWatts = portFound ? portTotal : nil

        // Live SMC battery current/voltage override if available
        if let bv = Self.readSMCIntegerSensor(key: 0x42304156, signed: false, exchange: exchange),
           let ba = Self.readSMCIntegerSensor(key: 0x42304143, signed: true, exchange: exchange),
           (3.0...25.0).contains(bv), abs(ba) <= 25.0 {
            voltageVolts = bv
            amperageMA = Int(round(ba * 1000.0))
            wattage = bv * ba
        }
    }

    private static func leUInt32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }

    private static func readSMCScalar(key: UInt32, exchange: ([UInt8]) -> [UInt8]?) -> Double? {
        var req = [UInt8](repeating: 0, count: 80)
        for i in 0..<4 { req[i] = UInt8(truncatingIfNeeded: key >> (i * 8)) }
        req[42] = 9 // read key info
        guard let info = exchange(req), info[40] == 0 else { return nil }
        let size = leUInt32(info, 28)
        let type = leUInt32(info, 32)
        switch (type, size) {
        case (0x666c7420, 4), (0x66706532, 2), (0x73703738, 2): break
        default: return nil
        }
        req.replaceSubrange(28..<32, with: info[28..<32])
        req[42] = 5 // read bytes
        guard let resp = exchange(req), resp[40] == 0 else { return nil }
        let val: Double
        if type == 0x666c7420 {
            val = Double(Float(bitPattern: leUInt32(resp, 48)))
        } else {
            let raw = (UInt16(resp[48]) << 8) | UInt16(resp[49])
            val = (type == 0x66706532) ? Double(raw) / 4.0 : Double(Int16(bitPattern: raw)) / 256.0
        }
        return val.isFinite ? val : nil
    }

    private static func readSMCIntegerSensor(key: UInt32, signed: Bool, exchange: ([UInt8]) -> [UInt8]?) -> Double? {
        var req = [UInt8](repeating: 0, count: 80)
        for i in 0..<4 { req[i] = UInt8(truncatingIfNeeded: key >> (i * 8)) }
        req[42] = 9
        guard let info = exchange(req), info[40] == 0 else { return nil }
        let size = leUInt32(info, 28)
        let type = leUInt32(info, 32)
        guard size == 2, (type == 0x73693136 || type == 0x75693136) else { return nil }
        req.replaceSubrange(28..<32, with: info[28..<32])
        req[42] = 5
        guard let resp = exchange(req), resp[40] == 0 else { return nil }
        let raw = UInt16(resp[48]) | (UInt16(resp[49]) << 8)
        let val = (signed ? Double(Int16(bitPattern: raw)) : Double(raw)) / 1000.0
        return val.isFinite ? val : nil
    }

    // MARK: - High Energy Apps Sampling (proc_pid_rusage RUSAGE_INFO_V6)

    private func sampleEnergyApps() {
        let myBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { app -> (path: String, name: String, icon: NSImage?)? in
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory,
                  let url = app.bundleURL else { return nil }
            let path = url.standardizedFileURL.path
            guard path != myBundlePath, path.hasSuffix(".app") else { return nil }
            // Exclude headless macOS system agents (e.g. MenuBarAgent, ControlCenter, WindowManager)
            // while preserving user-facing regular apps (including Finder / System Settings).
            if app.activationPolicy != .regular && path.hasPrefix("/System/Library/") {
                return nil
            }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            return (path, name, app.icon)
        }
        guard !runningApps.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let byteCount = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard byteCount > 0 else { return }
        let cap = min(Int(byteCount) / MemoryLayout<pid_t>.stride + 64, 8192)
        var pids = [pid_t](repeating: 0, count: cap)
        let returned = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        let pidCount = max(0, min(Int(returned) / MemoryLayout<pid_t>.stride, cap))

        var currentCounters: [String: RawAppCounter] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(pidCount) where pid > 0 {
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let execPath = String(decoding: pathBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let matched = runningApps
                .filter({ execPath.hasPrefix($0.path + "/") })
                .min(by: { $0.path.count < $1.path.count })
            else { continue }

            var usage = rusage_info_v6()
            let kr = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard kr == 0 else { continue }
            let cpu = usage.ri_user_time &+ usage.ri_system_time
            let energy = usage.ri_energy_nj
            let prev = currentCounters[matched.path] ?? RawAppCounter(cpuNs: 0, energyNj: 0)
            currentCounters[matched.path] = RawAppCounter(
                cpuNs: prev.cpuNs &+ cpu,
                energyNj: prev.energyNj &+ energy
            )
        }

        if let prevTime = lastAppSampleTime {
            let dt = max(0.4, now - prevTime)
            var items: [EnergyAppItem] = []
            var appLookup: [String: (name: String, icon: NSImage?)] = [:]
            for a in runningApps { appLookup[a.path] = (a.name, a.icon) }

            for (path, cur) in currentCounters {
                guard let prev = lastAppCounters[path], let info = appLookup[path] else { continue }
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
            highEnergyApps = Array(items.prefix(5))
            isSamplingEnergyApps = false
        } else {
            isSamplingEnergyApps = true
        }

        lastAppCounters = currentCounters
        lastAppSampleTime = now
    }
}
