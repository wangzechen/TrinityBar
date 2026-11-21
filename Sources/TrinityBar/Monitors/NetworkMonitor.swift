import AppKit
import CoreLocation
import CoreWLAN
import Darwin
import Foundation
import Network
import SystemConfiguration

enum ConnectionKind: Sendable, Equatable {
    case wifi
    case ethernet
    case other
    case offline
}

struct ScannedWiFiItem: Identifiable, Equatable, Sendable {
    let id: String // ssid
    let ssid: String
    let rssi: Int?
    let isSecured: Bool
    let isConnected: Bool
    let isKnown: Bool

    var signalVariableValue: Double {
        guard let rssi else { return 1.0 }
        if rssi >= -68 { return 1.0 }
        if rssi >= -78 { return 0.66 }
        if rssi >= -88 { return 0.33 }
        return 0.0
    }
}

@MainActor
final class NetworkMonitor: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var kind: ConnectionKind = .wifi
    @Published private(set) var wifiPowerOn: Bool = true
    @Published private(set) var ssid: String?
    @Published private(set) var bssid: String?
    @Published private(set) var rssi: Int?
    @Published private(set) var noiseDbm: Int?
    @Published private(set) var band: String?
    @Published private(set) var channelNumber: Int?
    @Published private(set) var channelWidth: String?
    @Published private(set) var phyMode: String?
    @Published private(set) var linkRateMbps: Double?
    @Published private(set) var securityText: String?
    @Published private(set) var countryCode: String?

    @Published private(set) var interfaceName: String = "en0"
    @Published private(set) var localIP: String = "—"
    @Published private(set) var ipv6Address: String?
    @Published private(set) var routerIP: String?
    @Published private(set) var dnsServers: String?

    @Published private(set) var downloadBytesPerSec: Double = 0
    @Published private(set) var uploadBytesPerSec: Double = 0
    @Published private(set) var pingMs: Int?

    @Published private(set) var knownNetworks: [ScannedWiFiItem] = []
    @Published private(set) var otherNetworks: [ScannedWiFiItem] = []
    @Published private(set) var isScanningWiFi: Bool = false
    @Published private(set) var needsLocationPermission: Bool = false

    /// 0...3 bars for center Wi-Fi symbol
    var wifiStrengthBars: Int {
        guard kind == .wifi else { return kind == .offline ? 0 : 3 }
        guard let rssi, rssi < 0 else { return 3 }
        if rssi >= -70 { return 3 }
        if rssi >= -78 { return 2 }
        if rssi >= -88 { return 1 }
        return 0
    }

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.zechen.trinitybar.network")
    private let wlanWorkerQueue = DispatchQueue(label: "com.zechen.trinitybar.wlanworker", qos: .utility)
    private let pingQueue = DispatchQueue(label: "com.zechen.trinitybar.ping", qos: .utility)
    private let locationManager = CLLocationManager()
    nonisolated(unsafe) private var liveSamplerTimer: Timer?
    nonisolated(unsafe) private var signalRefreshTimer: Timer?
    private var prevBytes: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    override init() {
        super.init()
        locationManager.delegate = self
        startPathMonitor()
        refreshStaticTelemetry()

        signalRefreshTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWifiAndIP()
            }
        }
    }

    deinit {
        liveSamplerTimer?.invalidate()
        signalRefreshTimer?.invalidate()
        pathMonitor.cancel()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshWifiAndIP()
        if isScanningWiFi || !knownNetworks.isEmpty || !otherNetworks.isEmpty {
            scanNearbyNetworks()
        }
    }

    func requestWiFiNameAccess() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func setWiFiPower(_ enabled: Bool) {
        wifiPowerOn = enabled
        wlanWorkerQueue.async { [weak self] in
            if let iface = CWWiFiClient.shared().interface() {
                try? iface.setPower(enabled)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshWifiAndIP()
                if enabled {
                    self?.scanNearbyNetworks()
                } else {
                    self?.knownNetworks = []
                    self?.otherNetworks = []
                }
            }
        }
    }

    func scanNearbyNetworks() {
        guard !isScanningWiFi else { return }
        isScanningWiFi = true

        wlanWorkerQueue.async { [weak self] in
            guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else {
                Task { @MainActor [weak self] in
                    self?.knownNetworks = []
                    self?.otherNetworks = []
                    self?.isScanningWiFi = false
                }
                return
            }

            let activeSSID = iface.ssid()
            let activeBSSID = iface.bssid()
            let profileNames: Set<String> = {
                guard let profiles = iface.configuration()?.networkProfiles else { return [] }
                var names = Set<String>()
                for item in profiles {
                    if let profile = item as? CWNetworkProfile, let s = profile.ssid {
                        names.insert(s)
                    }
                }
                return names
            }()

            var bestBySSID: [String: ScannedWiFiItem] = [:]
            if let rawSet = try? iface.scanForNetworks(withSSID: nil) {
                for net in rawSet {
                    guard let s = net.ssid, !s.isEmpty else { continue }
                    let rssiVal = net.rssiValue < 0 ? net.rssiValue : nil
                    let isBSSIDMatch: Bool = {
                        guard let activeBSSID, let candidateBSSID = net.bssid else { return false }
                        return candidateBSSID.caseInsensitiveCompare(activeBSSID) == .orderedSame
                    }()
                    let isConn = (activeSSID != nil && s == activeSSID) || isBSSIDMatch
                    let isKnown = isConn || profileNames.contains(s)
                    let secured = !net.supportsSecurity(.none)

                    let candidate = ScannedWiFiItem(
                        id: s,
                        ssid: s,
                        rssi: rssiVal,
                        isSecured: secured,
                        isConnected: isConn,
                        isKnown: isKnown
                    )

                    if let existing = bestBySSID[s] {
                        let oldRssi = existing.rssi ?? -120
                        let newRssi = rssiVal ?? -120
                        if isConn || newRssi > oldRssi {
                            bestBySSID[s] = ScannedWiFiItem(
                                id: s,
                                ssid: s,
                                rssi: max(oldRssi, newRssi),
                                isSecured: existing.isSecured || secured,
                                isConnected: existing.isConnected || isConn,
                                isKnown: existing.isKnown || isKnown
                            )
                        }
                    } else {
                        bestBySSID[s] = candidate
                    }
                }
            }

            // Ensure currently connected network is always listed even if hidden from beacon scan
            if let activeSSID, !activeSSID.isEmpty, bestBySSID[activeSSID] == nil {
                let r = iface.rssiValue()
                bestBySSID[activeSSID] = ScannedWiFiItem(
                    id: activeSSID,
                    ssid: activeSSID,
                    rssi: r < 0 ? r : nil,
                    isSecured: iface.security() != .none,
                    isConnected: true,
                    isKnown: true
                )
            }

            let allItems = Array(bestBySSID.values)
            let known = allItems
                .filter { $0.isKnown }
                .sorted { lhs, rhs in
                    if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
                    return (lhs.rssi ?? -100) > (rhs.rssi ?? -100)
                }
            let others = allItems
                .filter { !$0.isKnown }
                .sorted { ($0.rssi ?? -100) > ($1.rssi ?? -100) }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.knownNetworks = known
                self.otherNetworks = Array(others.prefix(12))
                self.isScanningWiFi = false
            }
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let detectedKind: ConnectionKind
            if path.status != .satisfied {
                detectedKind = .offline
            } else if path.usesInterfaceType(.wiredEthernet) {
                detectedKind = .ethernet
            } else if path.usesInterfaceType(.wifi) {
                detectedKind = .wifi
            } else {
                detectedKind = .other
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.kind = detectedKind
                self.refreshStaticTelemetry()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func setPopoverVisible(_ visible: Bool) {
        liveSamplerTimer?.invalidate()
        liveSamplerTimer = nil
        prevBytes = nil

        guard visible else { return }

        refreshStaticTelemetry()
        sampleThroughput()
        measurePing()

        var tick = 0
        liveSamplerTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampleThroughput()
                tick += 1
                if tick % 3 == 0 {
                    self.measurePing()
                    self.refreshWifiAndIP()
                }
            }
        }
    }

    func refreshStaticTelemetry() {
        refreshWifiAndIP()
    }

    private func refreshWifiAndIP() {
        if let iface = CWWiFiClient.shared().interface() {
            wifiPowerOn = iface.powerOn()
            if let bsd = iface.interfaceName {
                interfaceName = bsd
            }
            if wifiPowerOn, (kind == .wifi || iface.rssiValue() < 0) {
                let r = iface.rssiValue()
                rssi = r < 0 ? r : nil
                let n = iface.noiseMeasurement()
                noiseDbm = n < 0 ? n : nil

                let tx = iface.transmitRate()
                linkRateMbps = (tx.isFinite && tx > 0) ? tx : nil

                ssid = iface.ssid()
                bssid = iface.bssid()
                countryCode = iface.countryCode()

                let ch = iface.wlanChannel()
                channelNumber = ch?.channelNumber
                band = Self.displayBand(ch?.channelBand)
                channelWidth = Self.displayWidth(ch?.channelWidth)
                phyMode = Self.displayPHY(iface.activePHYMode())
                securityText = Self.displaySecurity(iface.security())

                let auth = locationManager.authorizationStatus
                needsLocationPermission = (rssi != nil && ssid == nil && auth != .authorizedAlways)
            } else {
                clearWirelessFields()
            }
        } else {
            clearWirelessFields()
        }

        let ipInfo = Self.readSystemNetworkDetails()
        localIP = ipInfo.ipv4 ?? Self.readLocalIPv4() ?? "—"
        ipv6Address = ipInfo.ipv6
        routerIP = ipInfo.router
        dnsServers = ipInfo.dns
        if let primaryIface = ipInfo.interfaceName {
            interfaceName = primaryIface
        }
    }

    private func clearWirelessFields() {
        rssi = nil
        noiseDbm = nil
        linkRateMbps = nil
        ssid = nil
        bssid = nil
        band = nil
        channelNumber = nil
        channelWidth = nil
        phyMode = nil
        securityText = nil
        countryCode = nil
        needsLocationPermission = false
    }

    private static func displayBand(_ band: CWChannelBand?) -> String? {
        guard let band else { return nil }
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        case .bandUnknown: return nil
        @unknown default: return nil
        }
    }

    private static func displayWidth(_ width: CWChannelWidth?) -> String? {
        guard let width else { return nil }
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        case .widthUnknown: return nil
        @unknown default: return nil
        }
    }

    private static func displayPHY(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n (Wi-Fi 4)"
        case .mode11ac: return "802.11ac (Wi-Fi 5)"
        case .mode11ax: return "802.11ax (Wi-Fi 6)"
        case .mode11be: return "802.11be (Wi-Fi 7)"
        case .modeNone: return nil
        @unknown default: return nil
        }
    }

    private static func displaySecurity(_ security: CWSecurity) -> String? {
        switch security {
        case .none:
            return "Open"
        case .WEP, .dynamicWEP:
            return "WEP"
        case .wpaPersonal, .wpaPersonalMixed:
            return "WPA"
        case .wpa2Personal:
            return "WPA2"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise, .enterprise:
            return "Enterprise"
        case .wpa3Personal, .wpa3Transition:
            return "WPA3"
        case .OWE, .oweTransition:
            return "OWE"
        case .personal:
            return "WPA2/WPA3"
        case .unknown:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - SCDynamicStore Gateway, DNS, IPv4 & IPv6

    private static func readSystemNetworkDetails() -> (
        interfaceName: String?,
        ipv4: String?,
        ipv6: String?,
        router: String?,
        dns: String?
    ) {
        guard let store = SCDynamicStoreCreate(nil, "TrinityBar" as CFString, nil, nil),
              let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else {
            return (nil, nil, readLocalIPv6(), nil, nil)
        }

        let primaryService = globalIPv4["PrimaryService"] as? String
        let primaryIface = globalIPv4["PrimaryInterface"] as? String
        let router = globalIPv4["Router"] as? String

        var ipv4: String? = nil
        var ipv6: String? = nil
        var dns: String? = nil

        if let svc = primaryService {
            if let v4Dict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(svc)/IPv4" as CFString) as? [String: Any],
               let addrs = v4Dict["Addresses"] as? [String], !addrs.isEmpty {
                ipv4 = addrs.joined(separator: ", ")
            }
            if let v6Dict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(svc)/IPv6" as CFString) as? [String: Any],
               let addrs = v6Dict["Addresses"] as? [String] {
                let filtered = addrs.filter { !$0.lowercased().hasPrefix("fe80:") }
                ipv6 = (filtered.first ?? addrs.first)
            }
            if let dnsDict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(svc)/DNS" as CFString) as? [String: Any]
                ?? SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(svc)/DNS" as CFString) as? [String: Any],
               let servers = dnsDict["ServerAddresses"] as? [String], !servers.isEmpty {
                dns = servers.prefix(3).joined(separator: ", ")
            }
        }

        if ipv6 == nil {
            ipv6 = readLocalIPv6()
        }
        return (primaryIface, ipv4, ipv6, router, dns)
    }

    private func sampleThroughput() {
        guard kind != .offline else {
            downloadBytesPerSec = 0
            uploadBytesPerSec = 0
            return
        }

        let counters = Self.readInterfaceBytes()
        let now = ProcessInfo.processInfo.systemUptime
        if let prev = prevBytes {
            let dt = max(0.2, now - prev.time)
            let dRx = counters.rx >= prev.rx ? Double(counters.rx - prev.rx) : 0
            let dTx = counters.tx >= prev.tx ? Double(counters.tx - prev.tx) : 0
            downloadBytesPerSec = dRx / dt
            uploadBytesPerSec = dTx / dt
        }
        prevBytes = (counters.rx, counters.tx, now)
    }

    private func measurePing() {
        guard kind != .offline else {
            pingMs = nil
            return
        }

        let target = preferredLatencyEndpoint()
        let start = DispatchTime.now()
        let conn = NWConnection(host: target.host, port: target.port, using: .tcp)
        let queue = pingQueue

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                let ms = max(1, Int(round(Double(elapsedNs) / 1_000_000.0)))
                conn.cancel()
                Task { @MainActor [weak self] in
                    self?.pingMs = ms
                }
            case .failed:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 2.5) {
            conn.cancel()
        }
    }

    /// Selects the user's configured public DNS server when available, falling back to Apple's global
    /// connectivity endpoint (`captive.apple.com:80`) when system DNS points to a local LAN router or tunnel.
    private func preferredLatencyEndpoint() -> (host: NWEndpoint.Host, port: NWEndpoint.Port) {
        if let dnsList = dnsServers {
            for candidate in dnsList.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if Self.isRoutablePublicIP(candidate) {
                    return (NWEndpoint.Host(candidate), 53)
                }
            }
        }
        return (NWEndpoint.Host("captive.apple.com"), 80)
    }

    private static func isRoutablePublicIP(_ ip: String) -> Bool {
        guard !ip.isEmpty else { return false }
        let lower = ip.lowercased()
        if lower.contains(":") {
            // Exclude IPv6 loopback (::1), link-local (fe80::/10), and unique-local (fc00::/7)
            return lower != "::1"
                && !lower.hasPrefix("fe80:")
                && !lower.hasPrefix("fc")
                && !lower.hasPrefix("fd")
        }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let (a, b) = (octets[0], octets[1])
        if a == 10 || a == 127 || a == 0 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 100 && (64...127).contains(b) { return false } // CGNAT / Tailscale
        if a == 198 && (b == 18 || b == 19) { return false }    // Local proxy / TUN fake-IP
        return true
    }

    private static func readLocalIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if name == "en0" || name == "en1" {
                            return ip
                        }
                        if fallback == nil {
                            fallback = ip
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return fallback
    }

    private static func readLocalIPv6() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let raw = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        let clean = raw.components(separatedBy: "%").first ?? raw
                        if !clean.lowercased().hasPrefix("fe80:") {
                            return clean
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return nil
    }

    private static func readInterfaceBytes() -> (rx: UInt64, tx: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip"),
                   let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    totalRx &+= UInt64(data.pointee.ifi_ibytes)
                    totalTx &+= UInt64(data.pointee.ifi_obytes)
                }
            }
            ptr = interface.ifa_next
        }
        return (totalRx, totalTx)
    }
}
