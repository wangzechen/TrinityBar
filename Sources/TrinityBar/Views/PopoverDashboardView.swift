import AppKit
import ServiceManagement
import SwiftUI

/// macOS System Settings deep links used across the dashboard.
enum SystemSettingsPane: String {
    case battery = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    case network = "x-apple.systempreferences:com.apple.Network-Settings.extension"
    case wifi = "x-apple.systempreferences:com.apple.wifi-settings-extension"
    case sharing = "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    case sound = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
    case bluetooth = "x-apple.systempreferences:com.apple.BluetoothSettings"

    @MainActor
    func open() {
        if let url = URL(string: rawValue) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Root router. Observes only `AppSettings` (route + disclosure state); each summary section observes its own
/// monitor so a 1.5s throughput tick re-evaluates only the network section instead of the whole panel.
struct PopoverDashboardView: View {
    let battery: BatteryMonitor
    let network: NetworkMonitor
    let audio: AudioVolumeMonitor
    let caffeinate: CaffeinateManager
    let systemIcons: SystemIconsManager
    @ObservedObject var settings: AppSettings
    var onDismissPanel: () -> Void

    init(
        battery: BatteryMonitor,
        network: NetworkMonitor,
        audio: AudioVolumeMonitor,
        caffeinate: CaffeinateManager,
        systemIcons: SystemIconsManager,
        settings: AppSettings,
        onDismissPanel: @escaping () -> Void = {}
    ) {
        self.battery = battery
        self.network = network
        self.audio = audio
        self.caffeinate = caffeinate
        self.systemIcons = systemIcons
        self.settings = settings
        self.onDismissPanel = onDismissPanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch settings.route {
                case .summary:
                    summaryContent
                case .battery:
                    BatteryDetailsPageView(
                        battery: battery,
                        settings: settings,
                        onBack: { settings.route = .summary },
                        onOpenBatterySettings: { openSettingsAndDismiss(.battery) }
                    )
                case .network:
                    NetworkDetailsPageView(
                        network: network,
                        settings: settings,
                        onBack: { settings.route = .summary },
                        onOpenNetworkSettings: {
                            openSettingsAndDismiss(network.kind == .ethernet ? .network : .wifi)
                        },
                        onOpenSharingSettings: { openSettingsAndDismiss(.sharing) }
                    )
                case .sound:
                    SoundDetailsPageView(
                        audio: audio,
                        settings: settings,
                        onBack: { settings.route = .summary },
                        onOpenSoundSettings: { openSettingsAndDismiss(.sound) },
                        onOpenBluetoothSettings: { openSettingsAndDismiss(.bluetooth) }
                    )
                }
            }
            .padding(14)

            Spacer(minLength: 0)
        }
        .frame(width: 332)
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            BatterySummarySection(
                battery: battery,
                onOpenDetails: {
                    battery.refresh(includeDetailedSensors: true)
                    settings.route = .battery
                },
                onOpenSettings: { openSettingsAndDismiss(.battery) }
            )
            Divider().opacity(0.45)

            NetworkSummarySection(
                network: network,
                onOpenDetails: {
                    network.refreshStaticTelemetry()
                    if network.kind != .ethernet && network.wifiPowerOn {
                        network.scanNearbyNetworks()
                    }
                    settings.route = .network
                },
                onOpenSettings: { openSettingsAndDismiss(.network) }
            )
            Divider().opacity(0.45)

            SoundSummarySection(
                audio: audio,
                onOpenDetails: {
                    audio.refresh()
                    settings.route = .sound
                },
                onOpenSettings: { openSettingsAndDismiss(.sound) }
            )
            Divider().opacity(0.45)

            SettingsDrawerSection(
                settings: settings,
                caffeinate: caffeinate,
                systemIcons: systemIcons,
                onDismissPanel: onDismissPanel
            ) {
                EmblemPreviewTile(battery: battery, network: network, audio: audio, settings: settings)
            }
        }
    }

    private func openSettingsAndDismiss(_ pane: SystemSettingsPane) {
        onDismissPanel()
        pane.open()
    }
}

// MARK: - 1. Battery Module

private struct BatterySummarySection: View {
    @ObservedObject var battery: BatteryMonitor
    let onOpenDetails: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryModuleHeaderRow(
                symbol: symbolName,
                symbolSize: 16,
                accentColor: accentColor,
                title: battery.hasBattery ? "Battery · \(battery.percentage)%" : "Power · AC",
                titleBadge: wattageBadge,
                subtitle: subtitle,
                detailsHelp: "Battery Power Flow & Details",
                settingsHelp: "Open Battery Settings",
                onOpenDetails: onOpenDetails,
                onOpenSettings: onOpenSettings
            )

            PowerInfoBarSection(battery: battery)
        }
    }

    private var wattageBadge: String? {
        guard let w = battery.wattage, abs(w) >= 0.15 else { return nil }
        return String(format: "%+.1fW", w)
    }

    private var symbolName: String {
        if !battery.hasBattery { return "powerplug.fill" }
        if battery.isCharging { return "battery.100percent.bolt" }
        if battery.percentage >= 88 { return "battery.100percent" }
        if battery.percentage >= 63 { return "battery.75percent" }
        if battery.percentage >= 38 { return "battery.50percent" }
        if battery.percentage >= 18 { return "battery.25percent" }
        return "battery.0percent"
    }

    private var accentColor: Color {
        switch battery.alertLevel {
        case .charging: return .green
        case .critical: return .red
        case .low: return .yellow
        case .normal: return .primary
        }
    }

    private var subtitle: String {
        if !battery.hasBattery {
            return battery.isLowPowerMode ? "AC Power · Low Power Mode" : "Desktop AC Power"
        }
        var parts: [String] = []
        if let mins = battery.timeRemainingMinutes {
            let duration = DisplayFormat.hoursMinutes(mins)
            parts.append(battery.isCharging ? "\(duration) to full" : "\(duration) left")
        } else if battery.isCharging {
            parts.append("Charging")
        } else if battery.isPluggedIn {
            parts.append("Connected to power")
        } else {
            parts.append(battery.isLowPowerMode ? "Low Power Mode" : "On battery")
        }

        if let health = battery.healthPercent {
            parts.append("Health \(health)%")
        }
        if let cycles = battery.cycleCount {
            parts.append("\(cycles) cyc")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 2. Network Module

private struct NetworkSummarySection: View {
    @ObservedObject var network: NetworkMonitor
    let onOpenDetails: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryModuleHeaderRow(
                symbol: symbolName,
                accentColor: isDown ? .red : .accentColor,
                title: title,
                subtitle: subtitle,
                detailsHelp: "Wi-Fi Networks & Link Details",
                settingsHelp: "Open Network Settings",
                onOpenDetails: onOpenDetails,
                onOpenSettings: onOpenSettings
            ) {
                if network.kind != .ethernet {
                    Button {
                        network.setWiFiPower(!network.wifiPowerOn)
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(network.wifiPowerOn ? Color.accentColor : .secondary)
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(network.wifiPowerOn ? "Turn Wi-Fi Off" : "Turn Wi-Fi On")
                }
            }

            NetworkInfoBarSection(network: network)
        }
    }

    private var isDown: Bool {
        network.kind == .offline || (network.kind == .wifi && !network.wifiPowerOn)
    }

    private var symbolName: String {
        switch network.kind {
        case .wifi: return network.wifiPowerOn ? "wifi" : "wifi.slash"
        case .ethernet: return "cable.connector.horizontal"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }

    private var title: String {
        switch network.kind {
        case .wifi:
            if !network.wifiPowerOn { return "Wi-Fi Off" }
            if let ssid = network.ssid, !ssid.isEmpty { return ssid }
            return "Wi-Fi"
        case .ethernet:
            return "Wired Ethernet"
        case .other:
            return "Connected"
        case .offline:
            return network.wifiPowerOn ? "No Network" : "Wi-Fi Off"
        }
    }

    private var subtitle: String {
        if isDown {
            return network.wifiPowerOn ? "Not connected" : "Radio powered off"
        }
        var parts: [String] = []
        if network.localIP != "—" && !network.localIP.isEmpty {
            parts.append(network.localIP)
        } else {
            parts.append(network.interfaceName)
        }
        if network.kind == .wifi, let phy = network.phyMode, !phy.isEmpty {
            parts.append(phy)
        } else if network.kind == .wifi, let rate = network.linkRateMbps, rate > 0 {
            parts.append("\(Int(round(rate))) Mbps")
        } else if !parts.contains(network.interfaceName) {
            parts.append(network.interfaceName)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 3. Sound Module

private struct SoundSummarySection: View {
    @ObservedObject var audio: AudioVolumeMonitor
    let onOpenDetails: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryModuleHeaderRow(
                symbol: audio.outputSymbolName,
                accentColor: audio.isMuted ? .red : .accentColor,
                title: audio.outputDeviceName,
                subtitle: subtitle,
                detailsHelp: "Switch Sound Output & Input Devices",
                settingsHelp: "Open Sound Settings",
                onOpenDetails: onOpenDetails,
                onOpenSettings: onOpenSettings
            )

            SoundInfoBarSection(audio: audio)
        }
    }

    private var subtitle: String {
        if audio.isMuted {
            return "\(audio.outputTransportLabel) · Muted"
        }
        if !audio.isVolumeControllable {
            return "\(audio.outputTransportLabel) · Fixed Volume"
        }
        if audio.outputDevices.count > 1 {
            return "\(audio.outputTransportLabel) · \(audio.outputDevices.count) outputs"
        }
        return "\(audio.outputTransportLabel) · Active"
    }
}

// MARK: - 4. Collapsible Settings Drawer

/// Live emblem preview inside the settings drawer; the only summary view that depends on every monitor.
private struct EmblemPreviewTile: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var network: NetworkMonitor
    @ObservedObject var audio: AudioVolumeMonitor
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 28, height: 28)
            TrinityEmblemView(
                state: .current(
                    battery: battery,
                    network: network,
                    audio: audio,
                    settings: settings,
                    isDarkMenuBar: colorScheme == .dark
                ),
                size: 20
            )
        }
    }
}

private struct SettingsDrawerSection<Preview: View>: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var caffeinate: CaffeinateManager
    @ObservedObject var systemIcons: SystemIconsManager
    let onDismissPanel: () -> Void
    @ViewBuilder let preview: () -> Preview
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let expanded = settings.summarySettingsExpanded
        VStack(alignment: .leading, spacing: expanded ? 9 : 0) {
            CollapsibleSectionHeader(
                title: "Settings",
                symbol: "slider.horizontal.3",
                isExpanded: expanded,
                onToggle: { settings.summarySettingsExpanded.toggle() }
            ) {
                if caffeinate.isKeepingAwake && !expanded {
                    HStack(spacing: 3) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(caffeinate.remainingBadgeText.map { "Awake · \($0)" } ?? "Awake")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.orange.opacity(0.15), in: Capsule(style: .continuous))
                }
            }

            drawerCard
                .opacity(expanded ? 1 : 0)
                .offset(y: expanded ? 0 : -4)
                .animation(.easeOut(duration: 0.18), value: expanded)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
                .frame(height: expanded ? nil : 0, alignment: .top)
        }
    }

    private var drawerCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                preview()

                Text("Volume Bar")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Picker("", selection: $settings.bottomMode) {
                    ForEach(BottomIndicatorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 164)
            }

            toggleRow("Top % Number", isOn: $settings.showTopPercentage)

            toggleRow(
                "Icon Volume Control",
                isOn: $settings.iconVolumeControl,
                help: "Scroll on the menu bar icon to adjust volume, and ⌥-Click to mute"
            )

            toggleRow(
                "Hide Native Icons",
                isOn: $systemIcons.autoHideEnabled,
                help: "Hide native macOS Wi-Fi, Battery, and Volume icons while TrinityBar is running"
            )

            if !systemIcons.isVerifiedOnThisMacOS {
                Text("Not yet verified on macOS \(systemIcons.macOSMajorVersion), so it starts off. Turn it on to try it.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text("Launch at Login")
                    .font(.system(size: 11.5))
                if settings.launchAtLoginRequiresApproval {
                    Button {
                        onDismissPanel()
                        SMAppService.openSystemSettingsLoginItems()
                    } label: {
                        Text("Approve…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Allow TrinityBar in System Settings → General → Login Items")
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Automatically launch TrinityBar when you log in to macOS")
            }

            Divider().opacity(0.35)

            keepAwakeRow

            HStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit TrinityBar")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Quit TrinityBar (⌘Q)")
            }
        }
        .padding(10)
        .glassCardSurface(
            fill: Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
            stroke: Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10)
        )
    }

    private var keepAwakeRow: some View {
        HStack(spacing: 6) {
            Button {
                caffeinate.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: caffeinate.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 11, weight: .semibold))
                    Text(keepAwakeButtonTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(caffeinate.isKeepingAwake ? Color.orange : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Prevent Mac display sleep")

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                ForEach(CaffeinateDuration.allCases) { duration in
                    let isSelected = caffeinate.selectedDuration == duration
                    Button {
                        caffeinate.activate(duration: duration)
                    } label: {
                        Text(duration.shortLabel)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? (caffeinate.isKeepingAwake ? Color.orange : Color.primary)
                                    : Color.secondary
                            )
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 2.5)
                            .background(
                                isSelected
                                    ? (caffeinate.isKeepingAwake
                                        ? Color.orange.opacity(0.18)
                                        : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))
                                    : Color.clear,
                                in: Capsule(style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(duration == .indefinite ? "Keep awake indefinitely" : "Keep awake for \(duration.shortLabel)")
                }
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(help ?? "")
        }
    }

    private var keepAwakeButtonTitle: String {
        guard caffeinate.isKeepingAwake else { return "Keep Awake" }
        if let rem = caffeinate.remainingBadgeText {
            return "Awake · \(rem)"
        }
        return "Awake On"
    }
}
