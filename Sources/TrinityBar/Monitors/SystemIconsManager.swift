import AppKit
import Foundation
import os

/// Manages hiding and restoring native macOS Control Center menu bar icons (`WiFi`, `Battery`, `Sound`)
/// while `TrinityBar` is running.
///
/// When `includesVolumeInEmblem` is `false` (`BottomIndicatorMode.none`), the native macOS `Sound` icon
/// is automatically shown in the status bar while `WiFi` and `Battery` remain governed by `autoHideEnabled`.
@MainActor
final class SystemIconsManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.zechen.trinitybar", category: "SystemIcons")
    private struct ManagedControlCenterItem {
        /// Control Center preference key name (e.g., `"WiFi"`, `"Battery"`, `"Sound"`).
        let moduleKey: String
        /// Short snapshot key suffix preserving backward compatibility with existing UserDefaults snapshots.
        let snapshotTag: String
        /// `byHost` integer written to hide the icon from the menu bar while keeping it in Control Center.
        let hiddenHostCode: Int
        /// `byHost` integer written when forcing default visibility (`18` = Always Show in Menu Bar).
        let visibleHostCode: Int = 18

        var statusItemVisibleKey: String { "NSStatusItem Visible \(moduleKey)" }
        var statusItemVisibleCCKey: String { "NSStatusItem VisibleCC \(moduleKey)" }

        var hostExistsKey: String { "TrinityBar.snap.host\(snapshotTag).exists" }
        var hostValKey: String { "TrinityBar.snap.host\(snapshotTag).val" }
        var visExistsKey: String { "TrinityBar.snap.vis\(snapshotTag).exists" }
        var visValKey: String { "TrinityBar.snap.vis\(snapshotTag).val" }
        var visCCExistsKey: String { "TrinityBar.snap.visCC\(snapshotTag).exists" }
        var visCCValKey: String { "TrinityBar.snap.visCC\(snapshotTag).val" }
    }

    private static let managedItems: [ManagedControlCenterItem] = [
        ManagedControlCenterItem(moduleKey: "WiFi", snapshotTag: "WiFi", hiddenHostCode: 24),
        ManagedControlCenterItem(moduleKey: "Battery", snapshotTag: "Batt", hiddenHostCode: 8),
        ManagedControlCenterItem(moduleKey: "Sound", snapshotTag: "Sound", hiddenHostCode: 8)
    ]

    private enum Keys {
        static let autoHideEnabledV2 = "TrinityBar.autoHideSystemIcons.v2"
        static let isCurrentlyHidden = "TrinityBar.systemIconsCurrentlyHidden"
        static let hasSnapshot = "TrinityBar.hasControlCenterSnapshot"
        static let hasSoundSnapshot = "TrinityBar.hasSoundControlCenterSnapshot"
    }

    private let domain = "com.apple.controlcenter" as CFString
    private var includesVolumeInEmblem: Bool = true

    @Published var autoHideEnabled: Bool {
        didSet {
            guard autoHideEnabled != oldValue else { return }
            UserDefaults.standard.set(autoHideEnabled, forKey: Keys.autoHideEnabledV2)
            applyCurrentPolicy()
        }
    }

    @Published private(set) var isCurrentlyHiddenByApp: Bool

    init() {
        let ud = UserDefaults.standard
        if ud.object(forKey: Keys.autoHideEnabledV2) == nil {
            self.autoHideEnabled = true
            ud.set(true, forKey: Keys.autoHideEnabledV2)
        } else {
            self.autoHideEnabled = ud.bool(forKey: Keys.autoHideEnabledV2)
        }
        self.isCurrentlyHiddenByApp = ud.bool(forKey: Keys.isCurrentlyHidden)
    }

    /// Updates whether TrinityBar's menu bar emblem currently displays volume (`Dots` / `Arc` = `true`, `None` = `false`).
    /// When `false`, the native macOS Sound icon is shown in the status bar automatically.
    func setIncludesVolumeInEmblem(_ includesVolume: Bool, applyImmediately: Bool = true) {
        guard includesVolumeInEmblem != includesVolume else { return }
        includesVolumeInEmblem = includesVolume
        if applyImmediately {
            applyCurrentPolicy()
        }
    }

    func applyOnLaunchIfNeeded() {
        if autoHideEnabled || !includesVolumeInEmblem {
            applyCurrentPolicy()
        } else if isCurrentlyHiddenByApp {
            restoreSystemIcons()
        }
    }

    func restoreOnTerminateIfNeeded() {
        guard isCurrentlyHiddenByApp else { return }
        restoreSystemIcons()
    }

    /// Applies the desired visibility for `WiFi`, `Battery`, and `Sound` based on `(autoHideEnabled, includesVolumeInEmblem)`.
    func applyCurrentPolicy() {
        let ud = UserDefaults.standard

        // If Hide Native Icons is OFF and Volume is shown in the emblem, restore everything to user's snapshot.
        if !autoHideEnabled && includesVolumeInEmblem {
            restoreSystemIcons()
            return
        }

        captureSnapshotsIfNeeded()

        for item in Self.managedItems {
            if item.moduleKey == "Sound" && !includesVolumeInEmblem {
                // Volume Bar == None -> explicitly show native Sound icon in the macOS status bar.
                applyDefaultVisible(item)
            } else if autoHideEnabled {
                applyHidden(item)
            } else {
                restoreItemOrDefault(item)
            }
        }

        syncPreferences()
        isCurrentlyHiddenByApp = true
        ud.set(true, forKey: Keys.isCurrentlyHidden)
        restartControlCenter()
    }

    func restoreSystemIcons() {
        let ud = UserDefaults.standard

        if ud.bool(forKey: Keys.hasSnapshot) {
            for item in Self.managedItems {
                restoreItemOrDefault(item)
            }
        } else {
            for item in Self.managedItems {
                applyDefaultVisible(item)
            }
        }

        syncPreferences()
        isCurrentlyHiddenByApp = false
        ud.set(false, forKey: Keys.isCurrentlyHidden)
        ud.synchronize()
        restartControlCenter()
    }

    // MARK: - Snapshot & CFPreferences Helpers

    private func captureSnapshotsIfNeeded() {
        let ud = UserDefaults.standard
        if !isCurrentlyHiddenByApp || !ud.bool(forKey: Keys.hasSnapshot) {
            for item in Self.managedItems {
                captureItemSnapshot(item)
            }
            ud.set(true, forKey: Keys.hasSnapshot)
            ud.set(true, forKey: Keys.hasSoundSnapshot)
        } else if !ud.bool(forKey: Keys.hasSoundSnapshot),
                  let soundItem = Self.managedItems.first(where: { $0.moduleKey == "Sound" }) {
            captureItemSnapshot(soundItem)
            ud.set(true, forKey: Keys.hasSoundSnapshot)
        }
    }

    private func captureItemSnapshot(_ item: ManagedControlCenterItem) {
        saveByHostSnapshot(key: item.moduleKey, existsKey: item.hostExistsKey, valKey: item.hostValKey)
        saveAnyHostSnapshot(key: item.statusItemVisibleKey, existsKey: item.visExistsKey, valKey: item.visValKey)
        saveAnyHostSnapshot(key: item.statusItemVisibleCCKey, existsKey: item.visCCExistsKey, valKey: item.visCCValKey)
    }

    private func restoreItemOrDefault(_ item: ManagedControlCenterItem) {
        let ud = UserDefaults.standard
        if item.moduleKey == "Sound" && !ud.bool(forKey: Keys.hasSoundSnapshot) {
            applyDefaultVisible(item)
        } else if ud.bool(forKey: Keys.hasSnapshot) {
            restoreItemSnapshot(item)
        } else {
            applyDefaultVisible(item)
        }
    }

    private func restoreItemSnapshot(_ item: ManagedControlCenterItem) {
        restoreByHostInt(key: item.moduleKey, existsKey: item.hostExistsKey, valKey: item.hostValKey)
        restoreAnyHostBool(key: item.statusItemVisibleKey, existsKey: item.visExistsKey, valKey: item.visValKey)
        restoreAnyHostBool(key: item.statusItemVisibleCCKey, existsKey: item.visCCExistsKey, valKey: item.visCCValKey)
    }

    private func applyHidden(_ item: ManagedControlCenterItem) {
        setByHostInt(key: item.moduleKey, value: item.hiddenHostCode)
        setAnyHostBool(key: item.statusItemVisibleKey, value: false)
        setAnyHostBool(key: item.statusItemVisibleCCKey, value: false)
    }

    private func applyDefaultVisible(_ item: ManagedControlCenterItem) {
        setByHostInt(key: item.moduleKey, value: item.visibleHostCode)
        setAnyHostBool(key: item.statusItemVisibleKey, value: true)
        setAnyHostBool(key: item.statusItemVisibleCCKey, value: true)
    }

    private func saveByHostSnapshot(key: String, existsKey: String, valKey: String) {
        let ud = UserDefaults.standard
        if let raw = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
           let num = raw as? NSNumber {
            ud.set(true, forKey: existsKey)
            ud.set(num.intValue, forKey: valKey)
        } else {
            ud.set(false, forKey: existsKey)
        }
    }

    private func saveAnyHostSnapshot(key: String, existsKey: String, valKey: String) {
        let ud = UserDefaults.standard
        if let raw = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
           let num = raw as? NSNumber {
            ud.set(true, forKey: existsKey)
            ud.set(num.boolValue, forKey: valKey)
        } else {
            ud.set(false, forKey: existsKey)
        }
    }

    private func setByHostInt(key: String, value: Int?) {
        let cfVal: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(key as CFString, cfVal, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private func setAnyHostBool(key: String, value: Bool?) {
        let cfVal: CFPropertyList? = value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }
        CFPreferencesSetValue(key as CFString, cfVal, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func restoreByHostInt(key: String, existsKey: String, valKey: String) {
        let ud = UserDefaults.standard
        if ud.bool(forKey: existsKey) {
            setByHostInt(key: key, value: ud.integer(forKey: valKey))
        } else {
            setByHostInt(key: key, value: nil)
        }
    }

    private func restoreAnyHostBool(key: String, existsKey: String, valKey: String) {
        let ud = UserDefaults.standard
        if ud.bool(forKey: existsKey) {
            setAnyHostBool(key: key, value: ud.bool(forKey: valKey))
        } else {
            setAnyHostBool(key: key, value: nil)
        }
    }

    private func syncPreferences() {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func restartControlCenter() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["ControlCenter"]
        do {
            try proc.run()
        } catch {
            Self.logger.error("Failed to restart ControlCenter: \(error.localizedDescription, privacy: .public)")
        }
    }
}
