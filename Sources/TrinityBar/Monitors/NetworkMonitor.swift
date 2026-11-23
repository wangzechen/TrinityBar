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

/// Shared RSSI -> 0...3 bar quantization so the menu bar emblem and the Wi-Fi list always agree.
enum WiFiSignal {
    static func bars(rssi: Int) -> Int {
        if rssi >= -70 { return 3 }
        if rssi >= -78 { return 2 }
        if rssi >= -88 { return 1 }
        return 0
    }

    /// SF Symbol `variableValue` for the `wifi` glyph.
    static func variableValue(bars: Int) -> Double {
        switch bars {
        case 3...: return 1.0
        case 2: return 0.66
        case 1: return 0.33
        default: return 0.0
        }
    }
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
        return WiFiSignal.variableValue(bars: WiFiSignal.bars(rssi: rssi))
    }
}

/// Immutable snapshot of CoreWLAN + SCDynamicStore link state, gathered off the main thread.
private struct LinkSnapshot: Sendable {
    struct Wireless: Sendable {
        var rssi: Int?
        var noiseDbm: Int?
        var linkRateMbps: Double?
        var ssid: String?
        var bssid: String?
        var countryCode: String?
        var channelNumber: Int?
        var band: String?
        var channelWidth: String?
        var phyMode: String?
        var securityText: String?
    }

    var wifiPowerOn: Bool?
    var wifiInterfaceName: String?
    /// `nil` when the Wi-Fi radio is off, absent, or not the active link.
    var wireless: Wireless?
    var ipv4: String?
    var ipv6: String?
    var router: String?
    var dns: String?
    var primaryInterfaceName: String?
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
    @Published private(set) var connectingSSID: String?
    @Published private(set) var needsLocationPermission: Bool = false

    /// 0...3 bars for center Wi-Fi symbol
    var wifiStrengthBars: Int {
        guard kind == .wifi else { return kind == .offline ? 0 : 3 }
        guard let rssi, rssi < 0 else { return 3 }
        return WiFiSignal.bars(rssi: rssi)
    }

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.zechen.trinitybar.network")
    private let wlanWorkerQueue = DispatchQueue(label: "com.zechen.trinitybar.wlanworker", qos: .utility)
    /// Dedicated serial queue for synchronous CoreWLAN / SCDynamicStore link reads so they never block the
    /// main thread and never queue behind multi-second Wi-Fi scans on `wlanWorkerQueue`.
    private let linkQueue = DispatchQueue(label: "com.zechen.trinitybar.link", qos: .utility)
    private let pingQueue = DispatchQueue(label: "com.zechen.trinitybar.ping", qos: .utility)
    private let locationManager = CLLocationManager()
    nonisolated(unsafe) private var liveSamplerTimer: Timer?
    nonisolated(unsafe) private var signalRefreshTimer: Timer?
    nonisolated(unsafe) private var activePingConnection: NWConnection?
    /// Accessed exclusively on `wlanWorkerQueue`.
    nonisolated(unsafe) private var scannedCWNets: [String: CWNetwork] = [:]
    private var prevBytes: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var liveSampleTick: Int = 0
    private var isRefreshingLink = false
    private var linkRefreshPending = false
    /// Optimistic Wi-Fi power state while `setPower` is in flight; link snapshots must not overwrite it.
    private var pendingWiFiPower: Bool?
    /// Bumped on every power change so snapshots read before the change never revert the toggle.
    private var wifiPowerSeq: UInt64 = 0

    override init() {
        super.init()
        locationManager.delegate = self
        startPathMonitor()
        refreshStaticTelemetry()

        let bgTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWifiAndIP()
            }
        }
        bgTimer.tolerance = 2.0
        signalRefreshTimer = bgTimer
    }

    deinit {
        liveSamplerTimer?.invalidate()
        signalRefreshTimer?.invalidate()
        activePingConnection?.stateUpdateHandler = nil
        activePingConnection?.cancel()
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
        pendingWiFiPower = enabled
        wifiPowerSeq &+= 1
        wlanWorkerQueue.async { [weak self] in
            if let iface = CWWiFiClient.shared().interface() {
                try? iface.setPower(enabled)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // setPower has returned: invalidate snapshots read before it, then let fresh reads apply
                // (a failed setPower simply reverts the toggle on the next refresh).
                self.wifiPowerSeq &+= 1
                if self.pendingWiFiPower == enabled { self.pendingWiFiPower = nil }

                try? await Task.sleep(for: .milliseconds(500))
                self.refreshWifiAndIP()
                if enabled {
                    self.scanNearbyNetworks()
                } else {
                    self.knownNetworks = []
                    self.otherNetworks = []
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
            var bestCWBySSID: [String: CWNetwork] = [:]
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
                            bestCWBySSID[s] = net
                        }
                    } else {
                        bestBySSID[s] = candidate
                        bestCWBySSID[s] = net
                    }
                }
            }
            self?.scannedCWNets = bestCWBySSID

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

    func connectToKnownNetwork(ssid targetSSID: String) async -> Bool {
        guard connectingSSID == nil, wifiPowerOn else { return false }
        connectingSSID = targetSSID

        let associated: Bool = await withCheckedContinuation { continuation in
            wlanWorkerQueue.async { [weak self] in
                var ok = false
                if let iface = CWWiFiClient.shared().interface(), iface.powerOn() {
                    let candidate: CWNetwork? = self?.scannedCWNets[targetSSID] ?? {
                        guard let data = targetSSID.data(using: .utf8),
                              let results = try? iface.scanForNetworks(withSSID: data) else {
                            return nil
                        }
                        return results.max(by: { $0.rssiValue < $1.rssiValue })
                    }()

                    if let targetNet = candidate {
                        do {
                            try iface.associate(to: targetNet, password: nil)
                            ok = true
                        } catch {
                            ok = false
                        }
                    }
                }
                continuation.resume(returning: ok)
            }
        }

        if associated {
            try? await Task.sleep(for: .milliseconds(600))
            connectingSSID = nil
            refreshWifiAndIP()
            scanNearbyNetworks()
            return true
        } else {
            connectingSSID = nil
            return false
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
                self.setIfChanged(\.kind, to: detectedKind)
                self.refreshStaticTelemetry()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func setPopoverVisible(_ visible: Bool) {
        liveSamplerTimer?.invalidate()
        liveSamplerTimer = nil
        prevBytes = nil

        guard visible else {
            cancelActivePing()
            return
        }

        refreshStaticTelemetry()
        sampleThroughput()
        measurePing()

        liveSampleTick = 0
        let liveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampleThroughput()
                self.liveSampleTick += 1
                if self.liveSampleTick % 3 == 0 {
                    self.measurePing()
                    self.refreshWifiAndIP()
                }
            }
        }
        liveTimer.tolerance = 0.2
        liveSamplerTimer = liveTimer
    }

    func refreshStaticTelemetry() {
        refreshWifiAndIP()
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<NetworkMonitor, T>, to value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// Reads CoreWLAN + SCDynamicStore link state on `linkQueue` (each CoreWLAN getter is a synchronous XPC
    /// round-trip to `airportd`) and applies the result on the main actor. Overlapping requests coalesce.
    private func refreshWifiAndIP() {
        if isRefreshingLink {
            linkRefreshPending = true
            return
        }
        isRefreshingLink = true
        let currentKind = kind
        let powerSeq = wifiPowerSeq
        linkQueue.async { [weak self] in
            let snapshot = Self.readLinkSnapshot(currentKind: currentKind)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyLinkSnapshot(snapshot, powerSeq: powerSeq)
                self.isRefreshingLink = false
                if self.linkRefreshPending {
                    self.linkRefreshPending = false
                    self.refreshWifiAndIP()
                }
            }
        }
    }

    private func applyLinkSnapshot(_ rawSnapshot: LinkSnapshot, powerSeq: UInt64) {
        let snapshot = ScreenshotMode.isActive ? Self.sanitizedForScreenshot(rawSnapshot) : rawSnapshot
        if let powerOn = snapshot.wifiPowerOn, pendingWiFiPower == nil, powerSeq == wifiPowerSeq {
            setIfChanged(\.wifiPowerOn, to: powerOn)
        }
        if let bsd = snapshot.wifiInterfaceName {
            setIfChanged(\.interfaceName, to: bsd)
        }

        let w = snapshot.wireless
        setIfChanged(\.rssi, to: w?.rssi)
        setIfChanged(\.noiseDbm, to: w?.noiseDbm)
        setIfChanged(\.linkRateMbps, to: w?.linkRateMbps)
        setIfChanged(\.ssid, to: w?.ssid)
        setIfChanged(\.bssid, to: w?.bssid)
        setIfChanged(\.countryCode, to: w?.countryCode)
        setIfChanged(\.channelNumber, to: w?.channelNumber)
        setIfChanged(\.band, to: w?.band)
        setIfChanged(\.channelWidth, to: w?.channelWidth)
        setIfChanged(\.phyMode, to: w?.phyMode)
        setIfChanged(\.securityText, to: w?.securityText)
        let needsLocation = w.map { $0.rssi != nil && $0.ssid == nil && locationManager.authorizationStatus != .authorizedAlways } ?? false
        setIfChanged(\.needsLocationPermission, to: needsLocation)

        setIfChanged(\.localIP, to: snapshot.ipv4 ?? "—")
        setIfChanged(\.ipv6Address, to: snapshot.ipv6)
        setIfChanged(\.routerIP, to: snapshot.router)
        setIfChanged(\.dnsServers, to: snapshot.dns)
        if let primaryIface = snapshot.primaryInterfaceName {
            setIfChanged(\.interfaceName, to: primaryIface)
        }
    }

    /// Replaces identifying network details with neutral demo values for README screenshots.
    private static func sanitizedForScreenshot(_ snapshot: LinkSnapshot) -> LinkSnapshot {
        var s = snapshot
        if s.wireless != nil {
            s.wireless?.ssid = ScreenshotMode.Demo.ssid
            s.wireless?.bssid = ScreenshotMode.Demo.bssid
        }
        if s.ipv4 != nil { s.ipv4 = ScreenshotMode.Demo.ipv4 }
        if s.ipv6 != nil { s.ipv6 = ScreenshotMode.Demo.ipv6 }
        if s.router != nil { s.router = ScreenshotMode.Demo.router }
        if s.dns != nil { s.dns = ScreenshotMode.Demo.dns }
        return s
    }

    nonisolated private static func readLinkSnapshot(currentKind: ConnectionKind) -> LinkSnapshot {
        var snapshot = LinkSnapshot()

        if let iface = CWWiFiClient.shared().interface() {
            let powerOn = iface.powerOn()
            snapshot.wifiPowerOn = powerOn
            snapshot.wifiInterfaceName = iface.interfaceName
            let r = iface.rssiValue()
            if powerOn, currentKind == .wifi || r < 0 {
                let n = iface.noiseMeasurement()
                let tx = iface.transmitRate()
                let ch = iface.wlanChannel()
                snapshot.wireless = LinkSnapshot.Wireless(
                    rssi: r < 0 ? r : nil,
                    noiseDbm: n < 0 ? n : nil,
                    linkRateMbps: (tx.isFinite && tx > 0) ? tx : nil,
                    ssid: iface.ssid(),
                    bssid: iface.bssid(),
                    countryCode: iface.countryCode(),
                    channelNumber: ch?.channelNumber,
                    band: displayBand(ch?.channelBand),
                    channelWidth: displayWidth(ch?.channelWidth),
                    phyMode: displayPHY(iface.activePHYMode()),
                    securityText: displaySecurity(iface.security())
                )
            }
        }

        let ipInfo = readSystemNetworkDetails()
        let fallbackIPs: (ipv4: String?, ipv6: String?)? = (ipInfo.ipv4 == nil || ipInfo.ipv6 == nil)
            ? readLocalIPAddresses()
            : nil
        snapshot.ipv4 = ipInfo.ipv4 ?? fallbackIPs?.ipv4
        snapshot.ipv6 = ipInfo.ipv6 ?? fallbackIPs?.ipv6
        snapshot.router = ipInfo.router
        snapshot.dns = ipInfo.dns
        snapshot.primaryInterfaceName = ipInfo.interfaceName
        return snapshot
    }

    nonisolated private static func displayBand(_ band: CWChannelBand?) -> String? {
        guard let band else { return nil }
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        case .bandUnknown: return nil
        @unknown default: return nil
        }
    }

    nonisolated private static func displayWidth(_ width: CWChannelWidth?) -> String? {
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

    nonisolated private static func displayPHY(_ mode: CWPHYMode) -> String? {
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

    nonisolated private static func displaySecurity(_ security: CWSecurity) -> String? {
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

    /// Only touched from `linkQueue`.
    nonisolated(unsafe) private static let dynamicStore: SCDynamicStore? =
        SCDynamicStoreCreate(nil, "TrinityBar" as CFString, nil, nil)

    nonisolated private static func readSystemNetworkDetails() -> (
        interfaceName: String?,
        ipv4: String?,
        ipv6: String?,
        router: String?,
        dns: String?
    ) {
        guard let store = dynamicStore,
              let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else {
            return (nil, nil, nil, nil, nil)
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

        return (primaryIface, ipv4, ipv6, router, dns)
    }

    private func sampleThroughput() {
        guard kind != .offline else {
            prevBytes = nil
            setIfChanged(\.downloadBytesPerSec, to: 0)
            setIfChanged(\.uploadBytesPerSec, to: 0)
            return
        }

        guard let counters = Self.readInterfaceBytes() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let prev = prevBytes {
            let dt = max(0.2, now - prev.time)
            let dRx = counters.rx >= prev.rx ? Double(counters.rx - prev.rx) : 0
            let dTx = counters.tx >= prev.tx ? Double(counters.tx - prev.tx) : 0
            setIfChanged(\.downloadBytesPerSec, to: dRx / dt)
            setIfChanged(\.uploadBytesPerSec, to: dTx / dt)
        }
        prevBytes = (counters.rx, counters.tx, now)
    }

    private func cancelActivePing() {
        activePingConnection?.stateUpdateHandler = nil
        activePingConnection?.cancel()
        activePingConnection = nil
    }

    private func measurePing() {
        cancelActivePing()
        guard kind != .offline else {
            setIfChanged(\.pingMs, to: nil)
            return
        }

        let target = preferredLatencyEndpoint()
        let start = DispatchTime.now()
        let conn = NWConnection(host: target.host, port: target.port, using: .tcp)
        activePingConnection = conn
        let queue = pingQueue

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                let ms = max(1, Int(round(Double(elapsedNs) / 1_000_000.0)))
                conn.stateUpdateHandler = nil
                conn.cancel()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.activePingConnection === conn { self.activePingConnection = nil }
                    guard self.kind != .offline else { return }
                    self.setIfChanged(\.pingMs, to: ms)
                }
            case .failed:
                conn.stateUpdateHandler = nil
                conn.cancel()
                Task { @MainActor [weak self] in
                    self?.finishFailedPing(conn)
                }
            default:
                break
            }
        }
        conn.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            conn.stateUpdateHandler = nil
            conn.cancel()
            Task { @MainActor [weak self] in
                self?.finishFailedPing(conn)
            }
        }
    }

    /// A probe that failed or timed out clears the stale latency, unless a newer probe already replaced it
    /// (a successful probe detaches itself from `activePingConnection`, so its timeout is a no-op).
    private func finishFailedPing(_ conn: NWConnection) {
        guard activePingConnection === conn else { return }
        activePingConnection = nil
        setIfChanged(\.pingMs, to: nil)
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

    nonisolated static func isRoutablePublicIP(_ ip: String) -> Bool {
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

    nonisolated private static func readLocalIPAddresses() -> (ipv4: String?, ipv6: String?) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (nil, nil) }
        defer { freeifaddrs(ifaddr) }

        var preferredV4: String?
        var fallbackV4: String?
        var preferredV6: String?
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let interface = current.pointee
            if let addr = interface.ifa_addr {
                let family = addr.pointee.sa_family
                if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                    let name = String(cString: interface.ifa_name)
                    let isPrimary = (name == "en0" || name == "en1")
                    let needsV4 = (family == UInt8(AF_INET)) && (preferredV4 == nil) && (name != "lo0")
                    let needsV6 = (family == UInt8(AF_INET6)) && (preferredV6 == nil) && isPrimary

                    if (needsV4 || needsV6),
                       getnameinfo(
                           addr,
                           socklen_t(addr.pointee.sa_len),
                           &hostname,
                           socklen_t(hostname.count),
                           nil,
                           0,
                           NI_NUMERICHOST
                       ) == 0 {
                        let raw = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if family == UInt8(AF_INET) {
                            if isPrimary {
                                preferredV4 = raw
                            } else if fallbackV4 == nil {
                                fallbackV4 = raw
                            }
                        } else {
                            let clean = raw.components(separatedBy: "%").first ?? raw
                            if !clean.lowercased().hasPrefix("fe80:") {
                                preferredV6 = clean
                            }
                        }
                    }
                }
            }
            if preferredV4 != nil && preferredV6 != nil { break }
            ptr = interface.ifa_next
        }
        return (preferredV4 ?? fallbackV4, preferredV6)
    }

    private static func readInterfaceBytes() -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buffer, &len, nil, 0) == 0 else {
            return nil
        }

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))

        buffer.withUnsafeBytes { rawBuf in
            var offset = 0
            while offset + 4 <= len {
                let msgLen = Int(rawBuf.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let msgType = rawBuf.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
                guard msgLen >= 4, offset + msgLen <= len else { break }

                if msgType == UInt8(RTM_IFINFO2),
                   msgLen >= MemoryLayout<if_msghdr2>.size {
                    let ifm2 = rawBuf.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(ifm2.ifm_index), &nameBuf) != nil {
                        let name = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            totalRx &+= ifm2.ifm_data.ifi_ibytes
                            totalTx &+= ifm2.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += msgLen
            }
        }

        return (totalRx, totalTx)
    }
}
