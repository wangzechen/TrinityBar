import AppKit
import Combine
import CoreGraphics
import Foundation
import os
import ServiceManagement

/// Bottom footer style inside the 24pt menu bar emblem (all modes represent audio volume).
enum BottomIndicatorMode: String, CaseIterable, Identifiable, Sendable {
    case volumeDots = "volumeDots"
    case volumeArc = "volumeArc"
    case none = "none"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .volumeDots: return "Dots"
        case .volumeArc: return "Arc"
        case .none: return "None"
        }
    }
}

/// Active navigation destination inside the popover panel.
/// Adding a new second-layer drill-down page only requires adding a case here and routing it in `PopoverDashboardView`.
enum PanelRoute: Equatable, Sendable {
    case summary
    case battery
    case network
    case sound
}

/// Centralized user preferences and transient UI navigation state.
/// Note: Transient UI state lives here rather than in SwiftUI `@State` properties so the entire target
/// compiles directly via `swiftc` without external macro plugin binaries.
@MainActor
final class AppSettings: ObservableObject {
    static let fixedIconSize: CGFloat = 24.0

    private static let logger = Logger(subsystem: "com.zechen.trinitybar", category: "AppSettings")

    private enum Keys {
        static let bottomMode = "TrinityBar.bottomMode.v2"
        static let showTopPercentage = "TrinityBar.showTopPercentage"
        static let iconVolumeControl = "TrinityBar.iconVolumeControl"
    }

    @Published var bottomMode: BottomIndicatorMode {
        didSet {
            UserDefaults.standard.set(bottomMode.rawValue, forKey: Keys.bottomMode)
        }
    }

    @Published var showTopPercentage: Bool {
        didSet {
            UserDefaults.standard.set(showTopPercentage, forKey: Keys.showTopPercentage)
        }
    }

    @Published var iconVolumeControl: Bool {
        didSet {
            UserDefaults.standard.set(iconVolumeControl, forKey: Keys.iconVolumeControl)
        }
    }

    // Login Items state backed directly by macOS ServiceManagement (SMAppService.mainApp)
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginRequiresApproval: Bool = false

    // Transient UI navigation & disclosure state
    @Published var route: PanelRoute = .summary
    @Published var summarySettingsExpanded: Bool = false
    @Published var wifiDetailsExpanded: Bool = true
    @Published var wifiShowMore: Bool = false
    @Published var soundDetailsExpanded: Bool = false
    @Published private(set) var copiedRowKey: String?

    private var copyResetTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.string(forKey: Keys.bottomMode) ?? BottomIndicatorMode.volumeDots.rawValue
        self.bottomMode = BottomIndicatorMode(rawValue: savedMode) ?? .volumeDots

        if defaults.object(forKey: Keys.showTopPercentage) == nil {
            self.showTopPercentage = true
        } else {
            self.showTopPercentage = defaults.bool(forKey: Keys.showTopPercentage)
        }

        if defaults.object(forKey: Keys.iconVolumeControl) == nil {
            self.iconVolumeControl = true
        } else {
            self.iconVolumeControl = defaults.bool(forKey: Keys.iconVolumeControl)
        }

        refreshLaunchAtLoginStatus()
    }

    /// Reads current Login Item registration state from macOS `SMAppService.mainApp`.
    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        launchAtLoginRequiresApproval = (status == .requiresApproval)
    }

    /// Registers or unregisters `TrinityBar.app` as a macOS Login Item.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.logger.error("Failed to update Launch at Login (\(enabled, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLoginStatus()
    }

    /// Writes `value` to the macOS pasteboard and flashes a temporary "Copied" confirmation on `key`.
    func copyToClipboard(_ value: String, key: String) {
        guard !value.isEmpty, value != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        copyResetTask?.cancel()
        copiedRowKey = key
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            if self?.copiedRowKey == key {
                self?.copiedRowKey = nil
            }
        }
    }
}
