import AppKit
import ServiceManagement
import SwiftUI

struct PopoverDashboardView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var network: NetworkMonitor
    @ObservedObject var audio: AudioVolumeMonitor
    @ObservedObject var caffeinate: CaffeinateManager
    @ObservedObject var systemIcons: SystemIconsManager
    @ObservedObject var settings: AppSettings
    var onDismissPanel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

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

    private var activeBottomDots: Int {
        switch settings.bottomMode {
        case .volumeDots: return audio.volumeDots
        case .volumeArc, .none: return 0
        }
    }

    private var emblemState: TrinityEmblemState {
        TrinityEmblemState(
            hasBattery: battery.hasBattery,
            batteryPercent: battery.percentage,
            isCharging: battery.isCharging,
            isPluggedIn: battery.isPluggedIn,
            isLowPowerMode: battery.isLowPowerMode,
            showTopPercentage: settings.showTopPercentage,
            connectionKind: network.kind,
            wifiStrengthBars: network.wifiStrengthBars,
            bottomMode: settings.bottomMode,
            bottomDots: activeBottomDots,
            bottomProgress: audio.effectiveProgress,
            isDarkMenuBar: colorScheme == .dark
        )
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
                        onOpenBatterySettings: {
                            openSettingsAndDismiss("x-apple.systempreferences:com.apple.Battery-Settings.extension")
                        }
                    )
                case .network:
                    NetworkDetailsPageView(
                        network: network,
                        settings: settings,
                        onBack: { settings.route = .summary },
                        onOpenNetworkSettings: {
                            let target = network.kind == .ethernet
                                ? "x-apple.systempreferences:com.apple.Network-Settings.extension"
                                : "x-apple.systempreferences:com.apple.wifi-settings-extension"
                            openSettingsAndDismiss(target)
                        },
                        onOpenSharingSettings: {
                            openSettingsAndDismiss("x-apple.systempreferences:com.apple.Sharing-Settings.extension")
                        }
                    )
                case .sound:
                    SoundDetailsPageView(
                        audio: audio,
                        settings: settings,
                        onBack: { settings.route = .summary },
                        onOpenSoundSettings: {
                            openSettingsAndDismiss("x-apple.systempreferences:com.apple.Sound-Settings.extension")
                        },
                        onOpenBluetoothSettings: {
                            openSettingsAndDismiss("x-apple.systempreferences:com.apple.BluetoothSettings")
                        }
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
            batterySection
            Divider().opacity(0.45)

            networkSection
            Divider().opacity(0.45)

            soundSection
            Divider().opacity(0.45)

            collapsedSettingsSection
        }
    }

    // MARK: - 1. Battery Module

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryModuleHeaderRow(
                symbol: batterySymbolName,
                symbolSize: 16,
                accentColor: batteryAccentColor,
                title: battery.hasBattery ? "Battery · \(battery.percentage)%" : "Power · AC",
                titleBadge: batteryWattageBadge,
                subtitle: batterySubtitle,
                detailsHelp: "Battery Power Flow & Details",
                settingsHelp: "Open Battery Settings",
                onOpenDetails: openBatteryDetails,
                onOpenSettings: {
                    openSettingsAndDismiss("x-apple.systempreferences:com.apple.Battery-Settings.extension")
                }
            )

            PowerInfoBarSection(battery: battery)
        }
    }

    private func openBatteryDetails() {
        battery.refresh(includeDetailedSensors: true)
        settings.route = .battery
    }

    // MARK: - 2. Network Module

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryModuleHeaderRow(
                symbol: networkSymbolName,
                accentColor: networkAccentColor,
                title: networkTitle,
                subtitle: networkSubtitle,
                detailsHelp: "Wi-Fi Networks & Link Details",
                settingsHelp: "Open Network Settings",
                onOpenDetails: openNetworkDetails,
                onOpenSettings: {
                    openSettingsAndDismiss("x-apple.systempreferences:com.apple.Network-Settings.extension")
                }
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

    private func openNetworkDetails() {
        network.refreshStaticTelemetry()
        if network.kind != .ethernet && network.wifiPowerOn {
            network.scanNearbyNetworks()
        }
        settings.route = .network
    }

    // MARK: - 3. Sound Module

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryModuleHeaderRow(
                symbol: audio.outputSymbolName,
                accentColor: audio.isMuted ? .red : .accentColor,
                title: audio.outputDeviceName,
                subtitle: soundSubtitle,
                detailsHelp: "Switch Sound Output & Input Devices",
                settingsHelp: "Open Sound Settings",
                onOpenDetails: openSoundDetails,
                onOpenSettings: {
                    openSettingsAndDismiss("x-apple.systempreferences:com.apple.Sound-Settings.extension")
                }
            )

            SoundInfoBarSection(audio: audio)
        }
    }

    private func openSoundDetails() {
        audio.refresh()
        settings.route = .sound
    }

    // MARK: - 4. Collapsible Settings Drawer

    private var collapsedSettingsSection: some View {
        VStack(alignment: .leading, spacing: settings.summarySettingsExpanded ? 9 : 0) {
            CollapsibleSectionHeader(
                title: "Settings",
                symbol: "slider.horizontal.3",
                isExpanded: settings.summarySettingsExpanded,
                onToggle: { settings.summarySettingsExpanded.toggle() }
            ) {
                if caffeinate.isKeepingAwake && !settings.summarySettingsExpanded {
                    HStack(spacing: 3) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(caffeinate.remainingBadgeText.map { "Awake · \($0)" } ?? "Awake")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.orange.opacity(0.15), in: Capsule(style: .continuous))
                }
            }

            settingsDrawerCard
                .opacity(settings.summarySettingsExpanded ? 1 : 0)
                .offset(y: settings.summarySettingsExpanded ? 0 : -4)
                .animation(.easeOut(duration: 0.18), value: settings.summarySettingsExpanded)
                .allowsHitTesting(settings.summarySettingsExpanded)
                .accessibilityHidden(!settings.summarySettingsExpanded)
                .frame(height: settings.summarySettingsExpanded ? nil : 0, alignment: .top)
        }
    }

    private var settingsDrawerCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 28, height: 28)
                    TrinityEmblemView(state: emblemState, size: 20)
                }

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

            HStack {
                Text("Top % Number")
                    .font(.system(size: 11.5))
                Spacer()
                Toggle("", isOn: $settings.showTopPercentage)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            HStack {
                Text("Icon Volume Control")
                    .font(.system(size: 11.5))
                Spacer()
                Toggle("", isOn: $settings.iconVolumeControl)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Scroll on the menu bar icon to adjust volume, and ⌥-Click to mute")
            }

            HStack {
                Text("Hide Native Icons")
                    .font(.system(size: 11.5))
                Spacer()
                Toggle("", isOn: $systemIcons.autoHideEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Hide native macOS Wi-Fi, Battery, and Volume icons while TrinityBar is running")
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
                    }
                }
            }

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
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 1)
        }
    }

    // MARK: - Formatting Helpers

    private var keepAwakeButtonTitle: String {
        guard caffeinate.isKeepingAwake else { return "Keep Awake" }
        if let rem = caffeinate.remainingBadgeText {
            return "Awake · \(rem)"
        }
        return "Awake On"
    }

    private var batteryWattageBadge: String? {
        guard let w = battery.wattage, abs(w) >= 0.15 else { return nil }
        return String(format: "%+.1fW", w)
    }

    private var batterySymbolName: String {
        if !battery.hasBattery { return "powerplug.fill" }
        if battery.isCharging { return "battery.100percent.bolt" }
        if battery.percentage >= 88 { return "battery.100percent" }
        if battery.percentage >= 63 { return "battery.75percent" }
        if battery.percentage >= 38 { return "battery.50percent" }
        if battery.percentage >= 18 { return "battery.25percent" }
        return "battery.0percent"
    }

    private var batteryAccentColor: Color {
        if !battery.hasBattery { return .primary }
        if battery.isCharging || battery.isPluggedIn { return .green }
        if battery.percentage <= 15 { return .red }
        if battery.isLowPowerMode || battery.percentage <= 20 { return .yellow }
        return .primary
    }

    private var batterySubtitle: String {
        if !battery.hasBattery {
            return battery.isLowPowerMode ? "AC Power · Low Power Mode" : "Desktop AC Power"
        }
        var parts: [String] = []
        if let mins = battery.timeRemainingMinutes {
            let h = mins / 60
            let m = mins % 60
            if battery.isCharging {
                parts.append(h > 0 ? "\(h)h \(m)m to full" : "\(m)m to full")
            } else {
                parts.append(h > 0 ? "\(h)h \(m)m left" : "\(m)m left")
            }
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

    private var networkSymbolName: String {
        switch network.kind {
        case .wifi: return network.wifiPowerOn ? "wifi" : "wifi.slash"
        case .ethernet: return "cable.connector.horizontal"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }

    private var networkAccentColor: Color {
        if network.kind == .offline || (network.kind == .wifi && !network.wifiPowerOn) {
            return .red
        }
        return .accentColor
    }

    private var networkTitle: String {
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

    private var networkSubtitle: String {
        if network.kind == .offline || (network.kind == .wifi && !network.wifiPowerOn) {
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

    private var soundSubtitle: String {
        if audio.isMuted {
            return "\(audio.outputTransportLabel) · Muted"
        }
        if audio.outputDevices.count > 1 {
            return "\(audio.outputTransportLabel) · \(audio.outputDevices.count) outputs"
        }
        return "\(audio.outputTransportLabel) · Active"
    }

    private func openSettingsAndDismiss(_ urlString: String) {
        onDismissPanel()
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
