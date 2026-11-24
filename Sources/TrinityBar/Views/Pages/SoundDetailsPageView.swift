import SwiftUI

// MARK: - Sound Output & Input Switching Page

struct SoundDetailsPageView: View {
    @ObservedObject var audio: AudioVolumeMonitor
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void
    let onOpenSoundSettings: () -> Void
    let onOpenBluetoothSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                NavigationBackHeader(title: "Sound", onBack: onBack)
                Button {
                    audio.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Refresh Audio Devices")
                .accessibilityLabel("Refresh Audio Devices")
            }

            // Live Mute + Capsule Volume Slider for whichever device is currently active
            SoundInfoBarSection(audio: audio)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 6) {
                Text("Output")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(audio.outputDevices) { item in
                    audioDeviceRow(item) {
                        audio.selectOutputDevice(item.id)
                    }
                }
            }

            if !audio.inputDevices.isEmpty {
                Divider().opacity(0.45)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Input")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(audio.inputDevices) { item in
                        audioDeviceRow(item) {
                            audio.selectInputDevice(item.id)
                        }
                    }
                }
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 7) {
                CollapsibleSectionHeader(
                    title: "Audio Details",
                    isExpanded: settings.soundDetailsExpanded,
                    onToggle: { settings.soundDetailsExpanded.toggle() }
                )

                if settings.soundDetailsExpanded {
                    VStack(alignment: .leading, spacing: 5) {
                        DetailKeyValueRow(
                            keyID: "snd.out",
                            label: "Output Device",
                            value: audio.outputDeviceName,
                            copyable: true,
                            settings: settings
                        )
                        DetailKeyValueRow(
                            keyID: "snd.tr",
                            label: "Connection",
                            value: audio.outputTransportLabel,
                            settings: settings
                        )
                        DetailKeyValueRow(
                            keyID: "snd.ch",
                            label: "Channels",
                            value: audio.outputChannelCount == 2 ? "2 ch (Stereo)" : "\(audio.outputChannelCount) ch",
                            settings: settings
                        )
                        if let rate = audio.outputSampleRateHz {
                            DetailKeyValueRow(
                                keyID: "snd.sr",
                                label: "Sample Rate",
                                value: String(format: "%.1f kHz", rate / 1000.0),
                                settings: settings
                            )
                        }
                        if let inName = audio.defaultInputDeviceName {
                            DetailKeyValueRow(
                                keyID: "snd.in",
                                label: "Input Device",
                                value: inName,
                                settings: settings
                            )
                        }
                    }
                }
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 7) {
                SettingsExternalLinkRow(title: "Sound Settings…", action: onOpenSoundSettings)
                SettingsExternalLinkRow(title: "Bluetooth Settings…", isSecondary: true, action: onOpenBluetoothSettings)
            }
        }
    }

    private func audioDeviceRow(_ item: AudioDeviceItem, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if item.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 14)
                } else {
                    Color.clear
                        .frame(width: 14, height: 14)
                }

                Image(systemName: item.symbolName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
                    .frame(width: 16)

                Text(item.name)
                    .font(.system(size: 12, weight: item.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.transportLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                item.isSelected ? Color.accentColor.opacity(0.11) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }
}
