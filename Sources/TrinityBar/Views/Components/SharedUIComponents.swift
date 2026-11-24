import AppKit
import SwiftUI

// MARK: - Display Formatting

enum DisplayFormat {
    /// `95` -> `"1h 35m"`, `40` -> `"40m"`.
    static func hoursMinutes(_ totalMinutes: Int) -> String {
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Glass Card Surface Helper

extension View {
    /// Applies TrinityBar's rounded Liquid Glass card fill + hairline stroke border.
    func glassCardSurface(fill: Color, stroke: Color, cornerRadius: CGFloat = 10) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
    }
}

// MARK: - Summary Liquid Glass Metric Card

/// Reusable rounded-10 Liquid Glass metric sub-card (`height: 40pt`) used across Power, Network, and Sound modules.
struct SummaryGlassMetricCard: View {
    let symbol: String
    let value: String
    let label: String
    let tint: Color
    var isSilver: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fill: Color = isSilver
            ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
            : tint.opacity(0.16)
        let stroke: Color = isSilver
            ? Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.15)
            : tint.opacity(0.30)

        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .padding(.horizontal, 5)
        .glassCardSurface(fill: fill, stroke: stroke)
    }
}

// MARK: - Summary Module Header Row

/// Standardized clickable module header row (`[Icon + Title/Badge + Subtitle] + [Optional Action] + [Chevron] + [Gearshape]`).
struct SummaryModuleHeaderRow<Accessory: View>: View {
    let symbol: String
    var symbolSize: CGFloat = 14.5
    let accentColor: Color
    let title: String
    var titleBadge: String? = nil
    let subtitle: String
    let detailsHelp: String
    let settingsHelp: String
    let onOpenDetails: () -> Void
    let onOpenSettings: () -> Void
    @ViewBuilder let trailingAccessory: () -> Accessory

    init(
        symbol: String,
        symbolSize: CGFloat = 14.5,
        accentColor: Color,
        title: String,
        titleBadge: String? = nil,
        subtitle: String,
        detailsHelp: String,
        settingsHelp: String,
        onOpenDetails: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        @ViewBuilder trailingAccessory: @escaping () -> Accessory
    ) {
        self.symbol = symbol
        self.symbolSize = symbolSize
        self.accentColor = accentColor
        self.title = title
        self.titleBadge = titleBadge
        self.subtitle = subtitle
        self.detailsHelp = detailsHelp
        self.settingsHelp = settingsHelp
        self.onOpenDetails = onOpenDetails
        self.onOpenSettings = onOpenSettings
        self.trailingAccessory = trailingAccessory
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpenDetails) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize, weight: .medium))
                        .foregroundStyle(accentColor)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                            if let badge = titleBadge {
                                Text(badge)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailingAccessory()

            Button(action: onOpenDetails) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(detailsHelp)
            .accessibilityLabel(detailsHelp)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(settingsHelp)
            .accessibilityLabel(settingsHelp)
        }
    }
}

extension SummaryModuleHeaderRow where Accessory == EmptyView {
    init(
        symbol: String,
        symbolSize: CGFloat = 14.5,
        accentColor: Color,
        title: String,
        titleBadge: String? = nil,
        subtitle: String,
        detailsHelp: String,
        settingsHelp: String,
        onOpenDetails: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.init(
            symbol: symbol,
            symbolSize: symbolSize,
            accentColor: accentColor,
            title: title,
            titleBadge: titleBadge,
            subtitle: subtitle,
            detailsHelp: detailsHelp,
            settingsHelp: settingsHelp,
            onOpenDetails: onOpenDetails,
            onOpenSettings: onOpenSettings,
            trailingAccessory: { EmptyView() }
        )
    }
}

// MARK: - Navigation & Disclosure Primitives

/// Top `< Title` back header shared across all second-layer detail pages.
struct NavigationBackHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityHint("Returns to the summary from \(title)")
    }
}

/// Reusable disclosure row with smooth `-180°` rotating chevron, used for Settings, Connection Details, and Audio Details.
struct CollapsibleSectionHeader<Badge: View>: View {
    let title: String
    var symbol: String? = nil
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let badge: () -> Badge

    init(
        title: String,
        symbol: String? = nil,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.title = title
        self.symbol = symbol
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.badge = badge
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.system(size: symbol == nil ? 11.5 : 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                badge()

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeOut(duration: 0.20), value: isExpanded)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

extension CollapsibleSectionHeader where Badge == EmptyView {
    init(
        title: String,
        symbol: String? = nil,
        isExpanded: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.init(
            title: title,
            symbol: symbol,
            isExpanded: isExpanded,
            onToggle: onToggle,
            badge: { EmptyView() }
        )
    }
}

// MARK: - Detail Telemetry Row & System Settings Link

/// Key-value telemetry row with optional click-to-copy pasteboard confirmation.
struct DetailKeyValueRow: View {
    let keyID: String
    let label: String
    let value: String
    var copyable: Bool = false
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if copyable, !value.isEmpty, value != "—" {
                Button {
                    settings.copyToClipboard(value, key: keyID)
                } label: {
                    HStack(spacing: 4) {
                        if settings.copiedRowKey == keyID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                        }
                        Text(settings.copiedRowKey == keyID ? "Copied" : value)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(settings.copiedRowKey == keyID ? Color.green : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to copy \(value)")
            } else {
                Text(value)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            }
        }
    }
}

/// Footer link row that opens a macOS System Settings pane.
struct SettingsExternalLinkRow: View {
    let title: String
    var isSecondary: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isSecondary ? .secondary : .primary)
                Spacer()
                if !isSecondary {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
