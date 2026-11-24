import AppKit
import Foundation
import os

/// Read/write access to the `com.apple.controlcenter` preference keys TrinityBar manages, injectable so the
/// hide / snapshot / restore policy can be unit-tested without touching the real menu bar.
@MainActor
protocol ControlCenterPreferences: AnyObject {
    /// `byHost` (current host) integer visibility code for a module key such as `"WiFi"`.
    func hostInt(forKey key: String) -> Int?
    func setHostInt(_ value: Int?, forKey key: String)
    /// Any-host boolean such as `"NSStatusItem Visible WiFi"`.
    func anyHostBool(forKey key: String) -> Bool?
    func setAnyHostBool(_ value: Bool?, forKey key: String)
    func synchronize()
}

/// Production `ControlCenterPreferences` backed by `CFPreferences`.
@MainActor
final class CFControlCenterPreferences: ControlCenterPreferences {
    private let domain = "com.apple.controlcenter" as CFString

    func hostInt(forKey key: String) -> Int? {
        (CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue
    }

    func setHostInt(_ value: Int?, forKey key: String) {
        let cfVal: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(key as CFString, cfVal, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    func anyHostBool(forKey key: String) -> Bool? {
        (CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.boolValue
    }

    func setAnyHostBool(_ value: Bool?, forKey key: String) {
        let cfVal: CFPropertyList? = value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }
        CFPreferencesSetValue(key as CFString, cfVal, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    func synchronize() {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

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

    /// Separate snapshot slot for the native Sound icon when it is force-shown with Hide Native Icons OFF
    /// (Volume Bar == None), so it never clobbers the main auto-hide snapshot.
    private static let forcedSoundItem = ManagedControlCenterItem(
        moduleKey: "Sound",
        snapshotTag: "SoundForced",
        hiddenHostCode: 8
    )

    private enum Keys {
        static let autoHideEnabledV2 = "TrinityBar.autoHideSystemIcons.v2"
        static let isCurrentlyHidden = "TrinityBar.systemIconsCurrentlyHidden"
        static let hasSnapshot = "TrinityBar.hasControlCenterSnapshot"
        static let hasSoundSnapshot = "TrinityBar.hasSoundControlCenterSnapshot"
        static let soundForcedVisible = "TrinityBar.soundForcedVisibleByApp"
    }

    private let defaults: UserDefaults
    private let preferences: ControlCenterPreferences
    private let restartControlCenterHandler: @MainActor () -> Void
    private var includesVolumeInEmblem: Bool = true

    @Published var autoHideEnabled: Bool {
        didSet {
            guard autoHideEnabled != oldValue else { return }
            defaults.set(autoHideEnabled, forKey: Keys.autoHideEnabledV2)
            applyCurrentPolicy()
        }
    }

    @Published private(set) var isCurrentlyHiddenByApp: Bool

    /// - Parameters:
    ///   - defaults: TrinityBar's own store for the opt-in flag and the pre-hide snapshots.
    ///   - preferences: The Control Center preference keys being hidden / restored.
    ///   - restartControlCenter: Applies written preferences (production: `killall ControlCenter`).
    init(
        defaults: UserDefaults = .standard,
        preferences: ControlCenterPreferences? = nil,
        restartControlCenter: (@MainActor () -> Void)? = nil
    ) {
        self.defaults = defaults
        self.preferences = preferences ?? CFControlCenterPreferences()
        self.restartControlCenterHandler = restartControlCenter ?? SystemIconsManager.killallControlCenter
        let ud = defaults
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
        // Also recovers a crash-leftover hidden / force-shown state when Hide Native Icons is OFF.
        applyCurrentPolicy()
    }

    func restoreOnTerminateIfNeeded() {
        restoreNativeIconsIfNeeded()
    }

    /// Hands every native icon TrinityBar hid or force-showed back to the user's own setting. Also used by
    /// `--restore-native-icons` after a crash or `SIGKILL`. Returns `true` when it had anything to restore.
    @discardableResult
    func restoreNativeIconsIfNeeded() -> Bool {
        var hadState = false
        if isCurrentlyHiddenByApp {
            hadState = true
            restoreSystemIcons()
        }
        if isSoundForcedVisible {
            hadState = true
            if releaseForcedSoundIfNeeded() {
                syncPreferences()
                restartControlCenter()
            }
        }
        return hadState
    }

    /// Applies the desired visibility for `WiFi`, `Battery`, and `Sound` based on `(autoHideEnabled, includesVolumeInEmblem)`.
    func applyCurrentPolicy() {
        let ud = defaults

        if !autoHideEnabled {
            if isCurrentlyHiddenByApp {
                restoreSystemIcons()
            }
            // When Hide Native Icons is OFF, only surface native Sound while Volume Bar is None (snapshotting
            // the user's own Sound setting first), and give it back once the emblem shows volume again.
            let changed = includesVolumeInEmblem ? releaseForcedSoundIfNeeded() : forceSoundVisibleIfNeeded()
            if changed {
                syncPreferences()
                restartControlCenter()
            }
            return
        }

        // Hand back any force-shown Sound icon before snapshotting, so the snapshot holds the user's real layout.
        let releasedForcedSound = releaseForcedSoundIfNeeded()
        if releasedForcedSound {
            syncPreferences()
        }
        captureSnapshotsIfNeeded()

        var changed = releasedForcedSound
        for item in Self.managedItems {
            if item.moduleKey == "Sound" && !includesVolumeInEmblem {
                // Volume Bar == None -> explicitly show native Sound icon in the macOS status bar.
                if applyDefaultVisible(item) { changed = true }
            } else {
                if applyHidden(item) { changed = true }
            }
        }

        isCurrentlyHiddenByApp = true
        ud.set(true, forKey: Keys.isCurrentlyHidden)
        if changed {
            syncPreferences()
            restartControlCenter()
        }
    }

    func restoreSystemIcons() {
        let ud = defaults
        var changed = false

        if ud.bool(forKey: Keys.hasSnapshot) {
            for item in Self.managedItems {
                if restoreItemOrDefault(item) { changed = true }
            }
        } else {
            for item in Self.managedItems {
                if applyDefaultVisible(item) { changed = true }
            }
        }

        isCurrentlyHiddenByApp = false
        ud.set(false, forKey: Keys.isCurrentlyHidden)
        ud.synchronize()
        if changed {
            syncPreferences()
            restartControlCenter()
        }
    }

    // MARK: - Forced Native Sound Icon (Hide Native Icons OFF + Volume Bar None)

    private var isSoundForcedVisible: Bool {
        defaults.bool(forKey: Keys.soundForcedVisible)
    }

    /// Returns `true` when Control Center preferences were changed.
    private func forceSoundVisibleIfNeeded() -> Bool {
        let item = Self.forcedSoundItem
        if !isSoundForcedVisible {
            captureItemSnapshot(item)
            defaults.set(true, forKey: Keys.soundForcedVisible)
        }
        return applyDefaultVisible(item)
    }

    /// Restores the user's own Sound icon setting if TrinityBar force-showed it. Returns `true` when preferences changed.
    @discardableResult
    private func releaseForcedSoundIfNeeded() -> Bool {
        guard isSoundForcedVisible else { return false }
        let changed = restoreItemSnapshot(Self.forcedSoundItem)
        defaults.set(false, forKey: Keys.soundForcedVisible)
        return changed
    }

    // MARK: - Snapshot & CFPreferences Helpers

    private func captureSnapshotsIfNeeded() {
        let ud = defaults
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

    @discardableResult
    private func restoreItemOrDefault(_ item: ManagedControlCenterItem) -> Bool {
        let ud = defaults
        if item.moduleKey == "Sound" && !ud.bool(forKey: Keys.hasSoundSnapshot) {
            return applyDefaultVisible(item)
        } else if ud.bool(forKey: Keys.hasSnapshot) {
            return restoreItemSnapshot(item)
        } else {
            return applyDefaultVisible(item)
        }
    }

    @discardableResult
    private func restoreItemSnapshot(_ item: ManagedControlCenterItem) -> Bool {
        let a = restoreByHostInt(key: item.moduleKey, existsKey: item.hostExistsKey, valKey: item.hostValKey)
        let b = restoreAnyHostBool(key: item.statusItemVisibleKey, existsKey: item.visExistsKey, valKey: item.visValKey)
        let c = restoreAnyHostBool(key: item.statusItemVisibleCCKey, existsKey: item.visCCExistsKey, valKey: item.visCCValKey)
        return a || b || c
    }

    @discardableResult
    private func applyHidden(_ item: ManagedControlCenterItem) -> Bool {
        let a = setByHostInt(key: item.moduleKey, value: item.hiddenHostCode)
        let b = setAnyHostBool(key: item.statusItemVisibleKey, value: false)
        let c = setAnyHostBool(key: item.statusItemVisibleCCKey, value: false)
        return a || b || c
    }

    @discardableResult
    private func applyDefaultVisible(_ item: ManagedControlCenterItem) -> Bool {
        let a = setByHostInt(key: item.moduleKey, value: item.visibleHostCode)
        let b = setAnyHostBool(key: item.statusItemVisibleKey, value: true)
        let c = setAnyHostBool(key: item.statusItemVisibleCCKey, value: true)
        return a || b || c
    }

    private func saveByHostSnapshot(key: String, existsKey: String, valKey: String) {
        if let value = preferences.hostInt(forKey: key) {
            defaults.set(true, forKey: existsKey)
            defaults.set(value, forKey: valKey)
        } else {
            defaults.set(false, forKey: existsKey)
        }
    }

    private func saveAnyHostSnapshot(key: String, existsKey: String, valKey: String) {
        if let value = preferences.anyHostBool(forKey: key) {
            defaults.set(true, forKey: existsKey)
            defaults.set(value, forKey: valKey)
        } else {
            defaults.set(false, forKey: existsKey)
        }
    }

    @discardableResult
    private func setByHostInt(key: String, value: Int?) -> Bool {
        guard preferences.hostInt(forKey: key) != value else { return false }
        preferences.setHostInt(value, forKey: key)
        return true
    }

    @discardableResult
    private func setAnyHostBool(key: String, value: Bool?) -> Bool {
        guard preferences.anyHostBool(forKey: key) != value else { return false }
        preferences.setAnyHostBool(value, forKey: key)
        return true
    }

    @discardableResult
    private func restoreByHostInt(key: String, existsKey: String, valKey: String) -> Bool {
        let ud = defaults
        if ud.bool(forKey: existsKey) {
            return setByHostInt(key: key, value: ud.integer(forKey: valKey))
        } else {
            return setByHostInt(key: key, value: nil)
        }
    }

    @discardableResult
    private func restoreAnyHostBool(key: String, existsKey: String, valKey: String) -> Bool {
        let ud = defaults
        if ud.bool(forKey: existsKey) {
            return setAnyHostBool(key: key, value: ud.bool(forKey: valKey))
        } else {
            return setAnyHostBool(key: key, value: nil)
        }
    }

    private func syncPreferences() {
        preferences.synchronize()
    }

    private func restartControlCenter() {
        restartControlCenterHandler()
    }

    private static func killallControlCenter() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["ControlCenter"]
        do {
            try proc.run()
        } catch {
            logger.error("Failed to restart ControlCenter: \(error.localizedDescription, privacy: .public)")
        }
    }
}
