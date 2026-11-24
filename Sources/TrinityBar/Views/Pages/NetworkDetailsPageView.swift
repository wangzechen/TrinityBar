import SwiftUI

// MARK: - Network / Wi-Fi Details Page (Wi-Fi List + Expandable Link Telemetry)

struct NetworkDetailsPageView: View {
    @ObservedObject var network: NetworkMonitor
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void
    let onOpenNetworkSettings: () -> Void
    let onOpenSharingSettings: () -> Void

    private var pageTitle: String {
        network.kind == .ethernet ? "Wired Ethernet" : "Wi-Fi"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                NavigationBackHeader(title: pageTitle, onBack: onBack)
                if network.kind != .ethernet {
                    Button {
                        network.scanNearbyNetworks()
                    } label: {
                        if network.isScanningWiFi {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(network.isScanningWiFi || !network.wifiPowerOn)
                    .help("Rescan Wi-Fi Networks")
                    .accessibilityLabel("Rescan Wi-Fi Networks")
                }
            }

            if network.kind != .ethernet {
                HStack {
                    Text("Wi-Fi Power")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("Wi-Fi Power", isOn: Binding(
                        get: { network.wifiPowerOn },
                        set: { network.setWiFiPower($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }

            if network.needsLocationPermission {
                Button {
                    network.requestWiFiNameAccess()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.blue)
                        Text("Allow Location Access to show Wi-Fi SSID & nearby names")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if network.kind != .ethernet && network.wifiPowerOn {
                wifiNetworksSection
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 7) {
                CollapsibleSectionHeader(
                    title: "Connection Details",
                    isExpanded: settings.wifiDetailsExpanded,
                    onToggle: { settings.wifiDetailsExpanded.toggle() }
                )

                if settings.wifiDetailsExpanded {
                    connectionDetailRows
                }
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 7) {
                SettingsExternalLinkRow(
                    title: network.kind == .ethernet ? "Network Settings…" : "Wi-Fi Settings…",
                    action: onOpenNetworkSettings
                )
                SettingsExternalLinkRow(
                    title: "Internet Sharing…",
                    isSecondary: true,
                    action: onOpenSharingSettings
                )
            }
        }
    }

    @ViewBuilder
    private var wifiNetworksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !network.knownNetworks.isEmpty {
                Text("Known Networks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(network.knownNetworks) { item in
                    scannedNetworkRow(item)
                }
            }

            if !network.otherNetworks.isEmpty {
                Text("Other Networks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, network.knownNetworks.isEmpty ? 0 : 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(network.otherNetworks) { item in
                            scannedNetworkRow(item)
                        }
                    }
                }
                .frame(maxHeight: 118)
            } else if network.knownNetworks.isEmpty && network.isScanningWiFi {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning nearby networks…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func scannedNetworkRow(_ item: ScannedWiFiItem) -> some View {
        let isConnecting = (network.connectingSSID == item.ssid)
        let joinFailed = (network.joinFailedSSID == item.ssid)
        return Button {
            guard !item.isConnected, network.connectingSSID == nil else { return }
            if item.isKnown && !joinFailed {
                // A failed join stays on this page with an inline note; a second click opens Wi-Fi Settings.
                Task { @MainActor in
                    _ = await network.connectToKnownNetwork(ssid: item.ssid)
                }
            } else {
                onOpenNetworkSettings()
            }
        } label: {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else if item.isConnected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 14)
                } else {
                    Image(systemName: "wifi", variableValue: item.signalVariableValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.ssid)
                        .font(.system(size: 12, weight: item.isConnected ? .semibold : .regular))
                        .lineLimit(1)
                    if joinFailed {
                        Text("Couldn't join. Click to open Wi-Fi Settings.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let r = item.rssi {
                    Text("\(r) dBm")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if item.isSecured {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(network.connectingSSID != nil)
        .help(item.isConnected ? "Connected" : ((item.isKnown && !joinFailed) ? "Join \(item.ssid)" : "Open Wi-Fi Settings to join"))
        .accessibilityAddTraits(item.isConnected ? .isSelected : [])
    }

    private var connectionDetailRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            if network.kind == .wifi {
                DetailKeyValueRow(
                    keyID: "net.ssid",
                    label: "SSID",
                    value: network.ssid ?? (network.needsLocationPermission ? "Hidden (Location Off)" : "—"),
                    copyable: network.ssid != nil,
                    settings: settings
                )
                if let bssid = network.bssid {
                    DetailKeyValueRow(keyID: "net.bssid", label: "BSSID", value: bssid, copyable: true, settings: settings)
                }
                if let band = network.band {
                    let chPart: String = {
                        if let ch = network.channelNumber, let w = network.channelWidth {
                            return "\(band) · Ch \(ch) (\(w))"
                        } else if let ch = network.channelNumber {
                            return "\(band) · Ch \(ch)"
                        }
                        return band
                    }()
                    DetailKeyValueRow(keyID: "net.chan", label: "Band / Channel", value: chPart, settings: settings)
                }
                if let rssi = network.rssi {
                    let snrPart: String = {
                        if let noise = network.noiseDbm {
                            return "\(rssi) dBm (SNR \(rssi - noise) dB)"
                        }
                        return "\(rssi) dBm"
                    }()
                    DetailKeyValueRow(keyID: "net.rssi", label: "Signal", value: snrPart, settings: settings)
                }
                if let phy = network.phyMode {
                    DetailKeyValueRow(keyID: "net.phy", label: "PHY Mode", value: phy, settings: settings)
                }
                if let tx = network.linkRateMbps {
                    DetailKeyValueRow(keyID: "net.tx", label: "Tx Rate", value: String(format: "%.0f Mbps", tx), settings: settings)
                }
                if let sec = network.securityText {
                    DetailKeyValueRow(keyID: "net.sec", label: "Security", value: sec, settings: settings)
                }
            }

            if network.kind != .wifi || settings.wifiShowMore {
                DetailKeyValueRow(keyID: "net.if", label: "Interface", value: network.interfaceName, settings: settings)
                DetailKeyValueRow(keyID: "net.ipv4", label: "IPv4", value: network.localIP, copyable: true, settings: settings)
                if let v6 = network.ipv6Address {
                    DetailKeyValueRow(keyID: "net.ipv6", label: "IPv6", value: v6, copyable: true, settings: settings)
                }
                if let gw = network.routerIP {
                    DetailKeyValueRow(keyID: "net.gw", label: "Router", value: gw, copyable: true, settings: settings)
                }
                if let dns = network.dnsServers {
                    DetailKeyValueRow(keyID: "net.dns", label: "DNS", value: dns, copyable: true, settings: settings)
                }
                if let ms = network.pingMs {
                    DetailKeyValueRow(keyID: "net.ping", label: "Latency", value: "\(ms) ms", settings: settings)
                }
            }

            if network.kind == .wifi {
                Button {
                    settings.wifiShowMore.toggle()
                } label: {
                    Text(settings.wifiShowMore ? "Show Less" : "Show More (IP, Router, DNS…)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
