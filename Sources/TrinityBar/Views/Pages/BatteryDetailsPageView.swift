import AppKit
import SwiftUI

// MARK: - Battery Details Page (Power Flow + Telemetry + High Energy Apps)

struct BatteryDetailsPageView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void
    let onOpenBatterySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            NavigationBackHeader(
                title: battery.hasBattery ? "Battery · \(battery.percentage)%" : "Power · AC",
                onBack: onBack
            )

            BatteryPowerFlowDiagram(battery: battery)

            Divider().opacity(0.45)

            VStack(spacing: 6) {
                DetailKeyValueRow(
                    keyID: "bat.source",
                    label: "Power Source",
                    value: powerSourceValue,
                    settings: settings
                )
                if battery.hasBattery {
                    DetailKeyValueRow(
                        keyID: "bat.time",
                        label: battery.isCharging ? "Time to Full" : "Time Remaining",
                        value: timeEstimateValue,
                        settings: settings
                    )
                    DetailKeyValueRow(
                        keyID: "bat.health",
                        label: "Battery Health",
                        value: healthDetailValue,
                        settings: settings
                    )
                    if let cycles = battery.cycleCount {
                        DetailKeyValueRow(
                            keyID: "bat.cycles",
                            label: "Cycle Count",
                            value: "\(cycles)",
                            settings: settings
                        )
                    }
                    if let temp = battery.temperatureCelsius {
                        DetailKeyValueRow(
                            keyID: "bat.temp",
                            label: "Temperature",
                            value: String(format: "%.1f °C", temp),
                            settings: settings
                        )
                    }
                    if let v = battery.voltageVolts {
                        let ampPart = battery.amperageMA.map { String(format: " · %+d mA", $0) } ?? ""
                        DetailKeyValueRow(
                            keyID: "bat.elec",
                            label: "Voltage / Current",
                            value: String(format: "%.2f V", v) + ampPart,
                            copyable: true,
                            settings: settings
                        )
                    }
                }
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 6) {
                Text("High Energy Apps")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                if battery.highEnergyApps.isEmpty {
                    Text(battery.isSamplingEnergyApps ? "Sampling live app energy…" : "No apps using significant energy")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(battery.highEnergyApps) { app in
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app")
                                    .font(.system(size: 13))
                                    .frame(width: 16, height: 16)
                                    .foregroundStyle(.secondary)
                            }
                            Text(app.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(app.powerText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider().opacity(0.45)

            SettingsExternalLinkRow(
                title: battery.hasBattery ? "Battery Settings…" : "Energy Settings…",
                action: onOpenBatterySettings
            )
        }
    }

    private var powerSourceValue: String {
        if battery.isPluggedIn {
            if let rated = battery.adapterRatedWatts {
                return "Power Adapter (\(rated) W)"
            }
            return "Power Adapter"
        }
        return battery.isLowPowerMode ? "Battery (Low Power)" : "Battery"
    }

    private var timeEstimateValue: String {
        if let mins = battery.timeRemainingMinutes {
            let h = mins / 60
            let m = mins % 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }
        if battery.isPluggedIn && !battery.isCharging && battery.percentage >= 98 {
            return "Fully Charged"
        }
        return "Calculating…"
    }

    private var healthDetailValue: String {
        var parts: [String] = []
        if let h = battery.healthPercent {
            parts.append("\(h)%")
        }
        if let maxCap = battery.maxCapacityMAh, let desCap = battery.designCapacityMAh {
            parts.append("\(maxCap)/\(desCap) mAh")
        } else {
            parts.append(battery.conditionText)
        }
        return parts.isEmpty ? battery.conditionText : parts.joined(separator: " · ")
    }
}

// MARK: - Sankey Power Flow Ribbon Diagram

private struct BatteryPowerFlowDiagram: View {
    @ObservedObject var battery: BatteryMonitor
    @Environment(\.colorScheme) private var colorScheme

    private struct BranchNode: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let watts: Double
        let hasLiveReading: Bool
        let color: Color
    }

    private var hasLivePowerReading: Bool {
        battery.adapterInputWatts != nil || battery.systemLoadWatts != nil || battery.wattage != nil
    }

    private var sourceNode: (label: String, detail: String?, symbol: String, watts: Double, hasLiveReading: Bool, color: Color, isSilver: Bool) {
        if battery.isPluggedIn {
            let live = hasLivePowerReading
            let w = battery.adapterInputWatts
                ?? max(0.5, (battery.systemLoadWatts ?? 4.0) + max(0.0, battery.wattage ?? 0.0))
            let detail = battery.adapterRatedWatts.map { "\($0)W Max" }
            return ("Adapter", detail, "powerplug.fill", w, live, .primary, true)
        } else {
            let live = hasLivePowerReading
            let discharge = abs(min(0.0, battery.wattage ?? -(battery.systemLoadWatts ?? 5.0)))
            let w = max(0.5, discharge > 0 ? discharge : (battery.systemLoadWatts ?? 5.0))
            return ("Battery", "\(battery.percentage)%", "battery.100percent", w, live, .orange, false)
        }
    }

    private var branches: [BranchNode] {
        var list: [BranchNode] = []
        let chgWatts = battery.isPluggedIn ? max(0.0, battery.wattage ?? 0.0) : 0.0
        if chgWatts >= 0.2 {
            list.append(BranchNode(id: "chg", label: "Charging", symbol: "battery.100percent.bolt", watts: chgWatts, hasLiveReading: true, color: .green))
        }

        let dispW = max(0.0, battery.displayWatts ?? 0.0)
        let usbW = max(0.0, battery.usbOutputWatts ?? 0.0)
        let totalSys = battery.systemLoadWatts ?? max(1.0, sourceNode.watts - chgWatts)
        let coreSys = max(0.5, totalSys - dispW - usbW)

        list.append(BranchNode(id: "sys", label: "System", symbol: "cpu", watts: coreSys, hasLiveReading: hasLivePowerReading, color: .blue))
        if dispW >= 0.15 {
            list.append(BranchNode(id: "disp", label: "Display", symbol: "display", watts: dispW, hasLiveReading: true, color: .indigo))
        }
        if usbW >= 0.10 {
            list.append(BranchNode(id: "usb", label: "USB Ports", symbol: "cable.connector", watts: usbW, hasLiveReading: true, color: .orange))
        }
        return list
    }

    var body: some View {
        let src = sourceNode
        let nodes = branches
        let totalBranchWatts = max(0.1, nodes.reduce(0.0) { $0 + $1.watts })
        let rowGap: CGFloat = 6
        let sourceHeight: CGFloat = 82
        let heights: [CGFloat] = nodes.map { node in
            let share = CGFloat(min(1.0, max(0.0, node.watts / totalBranchWatts)))
            return 24.0 + 44.0 * share
        }
        let colHeight = heights.reduce(0, +) + rowGap * CGFloat(max(0, nodes.count - 1))
        let totalHeight = max(sourceHeight, colHeight) + 4

        GeometryReader { geo in
            let w = geo.size.width
            let leftCardW: CGFloat = 68
            let rightCardW: CGFloat = 104
            let midY = totalHeight / 2.0

            let branchTopStart = (totalHeight - colHeight) / 2.0
            let centersY: [CGFloat] = {
                var result: [CGFloat] = []
                var acc = branchTopStart
                for h in heights {
                    result.append(acc + h / 2.0)
                    acc += h + rowGap
                }
                return result
            }()

            // Cubic Bezier ribbons from source right edge to branch left edges
            Canvas { ctx, _ in
                let bundleH = sourceHeight * 0.82
                var srcCursorY = midY - bundleH / 2.0
                let startX = leftCardW
                let endX = w - rightCardW
                let ctrl = (endX - startX) * 0.5

                for (idx, node) in nodes.enumerated() {
                    let frac = CGFloat(node.watts / totalBranchWatts)
                    let startThick = max(4.0, bundleH * frac)
                    let sY = srcCursorY + startThick / 2.0
                    srcCursorY += startThick

                    let eY = centersY[idx]
                    let endThick = min(startThick, max(4.0, heights[idx] - 8.0))

                    var ribbon = Path()
                    ribbon.move(to: CGPoint(x: startX, y: sY - startThick / 2.0))
                    ribbon.addCurve(
                        to: CGPoint(x: endX, y: eY - endThick / 2.0),
                        control1: CGPoint(x: startX + ctrl, y: sY - startThick / 2.0),
                        control2: CGPoint(x: endX - ctrl, y: eY - endThick / 2.0)
                    )
                    ribbon.addLine(to: CGPoint(x: endX, y: eY + endThick / 2.0))
                    ribbon.addCurve(
                        to: CGPoint(x: startX, y: sY + startThick / 2.0),
                        control1: CGPoint(x: endX - ctrl, y: eY + endThick / 2.0),
                        control2: CGPoint(x: startX + ctrl, y: sY + startThick / 2.0)
                    )
                    ribbon.closeSubpath()

                    ctx.fill(
                        ribbon,
                        with: .linearGradient(
                            Gradient(colors: [node.color.opacity(0.22), node.color.opacity(0.58)]),
                            startPoint: CGPoint(x: startX, y: sY),
                            endPoint: CGPoint(x: endX, y: eY)
                        )
                    )
                }
            }

            // Left Source Card
            VStack(spacing: 2) {
                Image(systemName: src.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(src.color)
                Text(src.hasLiveReading ? String(format: "%.1f W", src.watts) : "—")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(src.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                if let detail = src.detail {
                    Text(detail)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: leftCardW, height: sourceHeight)
            .glassCardSurface(
                fill: src.isSilver
                    ? Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07)
                    : src.color.opacity(0.18),
                stroke: src.isSilver
                    ? Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.16)
                    : src.color.opacity(0.32),
                cornerRadius: 11
            )
            .position(x: leftCardW / 2.0, y: midY)

            // Right Destination Branch Cards
            ForEach(Array(nodes.enumerated()), id: \.element.id) { idx, node in
                let cardH = heights[idx]
                let showLabel = cardH >= 36
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: node.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(node.color)
                            .frame(width: 16)
                        Text(node.hasLiveReading ? String(format: "%.1f W", node.watts) : "—")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    if showLabel {
                        Text(node.label)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .frame(width: rightCardW, height: cardH)
                .glassCardSurface(fill: node.color.opacity(0.18), stroke: node.color.opacity(0.32))
                .position(x: w - rightCardW / 2.0, y: centersY[idx])
            }
        }
        .frame(height: totalHeight)
    }
}
