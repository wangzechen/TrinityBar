import SwiftUI

// MARK: - 1. Power Summary Sub-Cards

struct PowerInfoBarSection: View {
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        HStack(spacing: 8) {
            SummaryGlassMetricCard(
                symbol: battery.isPluggedIn ? "powerplug.fill" : "powerplug",
                value: adapterText,
                label: "Adapter",
                tint: battery.isPluggedIn ? .primary : .secondary,
                isSilver: true
            )
            if battery.hasBattery {
                SummaryGlassMetricCard(
                    symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.100percent",
                    value: batteryWattsText,
                    label: battery.isCharging ? "Charging" : (battery.isPluggedIn ? "Battery" : "Discharging"),
                    tint: battery.isCharging ? .green : (battery.isPluggedIn ? .secondary : .orange),
                    isSilver: false
                )
            }
            SummaryGlassMetricCard(
                symbol: battery.hasBattery ? "laptopcomputer" : "desktopcomputer",
                value: systemWattsText,
                label: "System",
                tint: .blue,
                isSilver: false
            )
        }
    }

    private var adapterText: String {
        if !battery.isPluggedIn { return "—" }
        if let input = battery.adapterInputWatts {
            return String(format: "%.1f W", input)
        }
        if let rated = battery.adapterRatedWatts {
            return "\(rated) W"
        }
        return "On AC"
    }

    private var batteryWattsText: String {
        if let w = battery.wattage {
            if abs(w) < 0.15 { return "0.0 W" }
            return String(format: "%.1f W", abs(w))
        }
        return "—"
    }

    private var systemWattsText: String {
        if let sys = battery.systemLoadWatts {
            return String(format: "%.1f W", sys)
        }
        if !battery.isPluggedIn, let w = battery.wattage {
            return String(format: "%.1f W", abs(w))
        }
        return "—"
    }
}

// MARK: - 2. Network Summary Sub-Cards

struct NetworkInfoBarSection: View {
    @ObservedObject var network: NetworkMonitor

    var body: some View {
        HStack(spacing: 8) {
            SummaryGlassMetricCard(
                symbol: signalSymbol,
                value: signalValue,
                label: signalLabel,
                tint: signalTint,
                isSilver: network.kind != .offline
            )
            SummaryGlassMetricCard(
                symbol: "bolt.horizontal.fill",
                value: latencyValue,
                label: "Latency",
                tint: latencyTint,
                isSilver: network.pingMs == nil
            )
            SummaryGlassMetricCard(
                symbol: "arrow.down.circle.fill",
                value: "↓ \(Self.shortRate(network.downloadBytesPerSec))",
                label: "↑ \(Self.shortRate(network.uploadBytesPerSec))",
                tint: .indigo,
                isSilver: false
            )
        }
    }

    private var signalSymbol: String {
        switch network.kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }

    private var signalValue: String {
        switch network.kind {
        case .offline:
            return "Offline"
        case .ethernet:
            return "Wired"
        case .other:
            return "Active"
        case .wifi:
            if let rssi = network.rssi {
                return "\(rssi) dBm"
            }
            return network.wifiPowerOn ? "On" : "Off"
        }
    }

    private var signalLabel: String {
        if network.kind == .wifi, let band = network.band {
            return band
        }
        return "Signal"
    }

    private var signalTint: Color {
        if network.kind == .offline { return .red }
        return .primary
    }

    private var latencyValue: String {
        if network.kind == .offline { return "—" }
        if let ms = network.pingMs {
            return "\(ms) ms"
        }
        return "…"
    }

    private var latencyTint: Color {
        guard network.kind != .offline, let ms = network.pingMs else { return .secondary }
        if ms < 60 { return .green }
        if ms < 140 { return .orange }
        return .red
    }

    private static func shortRate(_ bps: Double) -> String {
        if bps < 1024 {
            return "0 K/s"
        } else if bps < 1024 * 1024 {
            return String(format: "%.0f K/s", bps / 1024.0)
        } else {
            return String(format: "%.1f M/s", bps / (1024.0 * 1024.0))
        }
    }
}

// MARK: - 3. Sound Summary Sub-Cards

struct SoundInfoBarSection: View {
    @ObservedObject var audio: AudioVolumeMonitor
    @Environment(\.colorScheme) private var colorScheme

    private var effectiveLevel: Double {
        audio.effectiveProgress
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                audio.toggleMute()
            } label: {
                SummaryGlassMetricCard(
                    symbol: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    value: audio.volumeLevelText,
                    label: audio.isMuted ? "Tap Unmute" : "Volume",
                    tint: audio.isMuted ? .red : .primary,
                    isSilver: !audio.isMuted
                )
            }
            .buttonStyle(.plain)
            .frame(width: 94)
            .disabled(!audio.isMuteControllable)
            .help(audio.isMuteControllable
                ? (audio.isMuted ? "Unmute Output" : "Mute Output")
                : "This output's volume is controlled by the device")

            // Glass Capsule Volume Slider Card
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    let fillW = max(0, min(w, w * CGFloat(effectiveLevel)))
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12))
                            .frame(height: 10)

                        if fillW > 1 {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.90))
                                .frame(width: max(10, fillW), height: 10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let pct = min(1.0, max(0.0, drag.location.x / w))
                                audio.setVolume(Float(pct))
                            }
                    )
                }
                .frame(height: 24)
                .allowsHitTesting(audio.isVolumeControllable)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .glassCardSurface(
                fill: Color.accentColor.opacity(0.12),
                stroke: Color.accentColor.opacity(0.26)
            )
            .opacity(audio.isVolumeControllable ? 1.0 : 0.45)
            .help(audio.isVolumeControllable ? "Drag to set the output volume" : "This output's volume is controlled by the device")
        }
    }
}
