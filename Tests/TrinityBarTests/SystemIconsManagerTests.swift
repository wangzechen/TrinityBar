import XCTest
@testable import TrinityBar

/// In-memory stand-in for the `com.apple.controlcenter` preference domain.
@MainActor
private final class FakeControlCenterPreferences: ControlCenterPreferences {
    var host: [String: Int]
    var anyHost: [String: Bool]
    private(set) var synchronizeCount = 0

    init(host: [String: Int] = [:], anyHost: [String: Bool] = [:]) {
        self.host = host
        self.anyHost = anyHost
    }

    func hostInt(forKey key: String) -> Int? { host[key] }
    func setHostInt(_ value: Int?, forKey key: String) { host[key] = value }
    func anyHostBool(forKey key: String) -> Bool? { anyHost[key] }
    func setAnyHostBool(_ value: Bool?, forKey key: String) {
        // Simulates macOS refusing to store a key (e.g. a format change after an update).
        guard !ignoredAnyHostKeys.contains(key) else { return }
        anyHost[key] = value
    }
    func synchronize() { synchronizeCount += 1 }
    var ignoredAnyHostKeys: Set<String> = []
}

/// Collects deferred work so tests decide when the coalesced ControlCenter restart runs.
@MainActor
private final class ManualScheduler {
    private var work: [@MainActor () -> Void] = []
    var pendingCount: Int { work.count }

    func schedule(_ item: @escaping @MainActor () -> Void) { work.append(item) }

    func runAll() {
        let items = work
        work.removeAll()
        items.forEach { $0() }
    }
}

@MainActor
private final class RestartCounter {
    var count = 0
}

@MainActor
final class SystemIconsManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var prefs: FakeControlCenterPreferences!
    private var restarts: RestartCounter!

    /// A user layout where Wi-Fi and Battery are shown with explicit values and Sound has never been configured.
    private let userHost: [String: Int] = ["WiFi": 2, "Battery": 3]
    private let userAnyHost: [String: Bool] = [
        "NSStatusItem Visible WiFi": true,
        "NSStatusItem Visible Battery": true,
        "NSStatusItem VisibleCC Battery": true,
    ]

    override func setUp() async throws {
        suiteName = "TrinityBarTests.SystemIcons.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        prefs = FakeControlCenterPreferences(host: userHost, anyHost: userAnyHost)
        restarts = RestartCounter()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        prefs = nil
        restarts = nil
    }

    /// - Parameter scheduler: `nil` runs deferred restarts immediately, so most tests can count restarts synchronously.
    private func makeManager(
        autoHide: Bool? = nil,
        macOSMajor: Int = 26,
        scheduler: ManualScheduler? = nil
    ) -> SystemIconsManager {
        if let autoHide {
            defaults.set(autoHide, forKey: "TrinityBar.autoHideSystemIcons.v2")
        }
        let counter = restarts!
        return SystemIconsManager(
            defaults: defaults,
            preferences: prefs,
            restartControlCenter: { counter.count += 1 },
            macOSMajorVersion: macOSMajor,
            scheduleDeferred: { work in
                if let scheduler { scheduler.schedule(work) } else { work() }
            }
        )
    }

    private func assertHidden(_ module: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectedCode = module == "WiFi" ? 24 : 8
        XCTAssertEqual(prefs.host[module], expectedCode, module, file: file, line: line)
        XCTAssertEqual(prefs.anyHost["NSStatusItem Visible \(module)"], false, module, file: file, line: line)
        XCTAssertEqual(prefs.anyHost["NSStatusItem VisibleCC \(module)"], false, module, file: file, line: line)
    }

    private func assertForcedVisible(_ module: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(prefs.host[module], 18, module, file: file, line: line)
        XCTAssertEqual(prefs.anyHost["NSStatusItem Visible \(module)"], true, module, file: file, line: line)
        XCTAssertEqual(prefs.anyHost["NSStatusItem VisibleCC \(module)"], true, module, file: file, line: line)
    }

    private func assertUserLayoutRestored(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(prefs.host, userHost, file: file, line: line)
        XCTAssertEqual(prefs.anyHost, userAnyHost, file: file, line: line)
    }

    // MARK: - Hide Native Icons ON (default)

    func testHideNativeIconsIsOnByDefaultAndHidesAllThree() {
        let manager = makeManager()
        XCTAssertTrue(manager.autoHideEnabled)

        manager.applyOnLaunchIfNeeded()

        assertHidden("WiFi")
        assertHidden("Battery")
        assertHidden("Sound")
        XCTAssertTrue(manager.isCurrentlyHiddenByApp)
        XCTAssertEqual(restarts.count, 1)
    }

    func testQuitRestoresExactUserLayoutIncludingAbsentKeys() {
        let manager = makeManager()
        manager.applyOnLaunchIfNeeded()

        manager.restoreOnTerminateIfNeeded()

        // Sound had no keys before TrinityBar touched it, so they must be removed, not set to a default.
        assertUserLayoutRestored()
        XCTAssertNil(prefs.host["Sound"])
        XCTAssertFalse(manager.isCurrentlyHiddenByApp)
    }

    func testTurningHideOffRestoresUserLayout() {
        let manager = makeManager()
        manager.applyOnLaunchIfNeeded()

        manager.autoHideEnabled = false

        assertUserLayoutRestored()
        XCTAssertFalse(defaults.bool(forKey: "TrinityBar.autoHideSystemIcons.v2"))
    }

    func testVolumeBarNoneShowsNativeSoundThenDotsHidesItAgain() {
        let manager = makeManager()
        manager.applyOnLaunchIfNeeded()

        manager.setIncludesVolumeInEmblem(false)
        assertForcedVisible("Sound")
        assertHidden("WiFi")
        assertHidden("Battery")

        manager.setIncludesVolumeInEmblem(true)
        assertHidden("Sound")

        manager.restoreOnTerminateIfNeeded()
        assertUserLayoutRestored()
    }

    func testRelaunchAfterCrashWhileHiddenKeepsOriginalSnapshot() {
        let crashed = makeManager()
        crashed.applyOnLaunchIfNeeded()
        // Simulated crash: restoreOnTerminateIfNeeded() never runs, prefs stay hidden.

        let relaunched = makeManager()
        XCTAssertTrue(relaunched.isCurrentlyHiddenByApp)
        relaunched.applyOnLaunchIfNeeded()
        assertHidden("WiFi")

        relaunched.restoreOnTerminateIfNeeded()
        // Must restore the pre-crash user layout, not the hidden values present at relaunch.
        assertUserLayoutRestored()
    }

    func testRelaunchAfterCrashWithHideTurnedOffRestoresOnLaunch() {
        let crashed = makeManager()
        crashed.applyOnLaunchIfNeeded()

        // The user turned Hide Native Icons off while the app wasn't running (e.g. via defaults).
        let relaunched = makeManager(autoHide: false)
        relaunched.applyOnLaunchIfNeeded()

        assertUserLayoutRestored()
    }

    // MARK: - --restore-native-icons

    func testRestoreCommandAfterCrashWhileHiddenRestoresUserLayout() {
        let crashed = makeManager()
        crashed.applyOnLaunchIfNeeded()
        let restartsBefore = restarts.count

        // `--restore-native-icons` builds a fresh manager without applying the launch policy.
        let restorer = makeManager()
        XCTAssertTrue(restorer.restoreNativeIconsIfNeeded())

        assertUserLayoutRestored()
        XCTAssertFalse(defaults.bool(forKey: "TrinityBar.systemIconsCurrentlyHidden"))
        XCTAssertEqual(restarts.count, restartsBefore + 1)
        // Running it again finds nothing left to do.
        XCTAssertFalse(makeManager().restoreNativeIconsIfNeeded())
    }

    func testRestoreCommandAfterCrashWhileSoundForcedGivesBackUserSetting() {
        let crashed = makeManager(autoHide: false)
        crashed.setIncludesVolumeInEmblem(false)
        assertForcedVisible("Sound")

        XCTAssertTrue(makeManager().restoreNativeIconsIfNeeded())

        assertUserLayoutRestored()
    }

    func testRestoreCommandWithNothingHiddenDoesNothing() {
        XCTAssertFalse(makeManager().restoreNativeIconsIfNeeded())

        assertUserLayoutRestored()
        XCTAssertEqual(restarts.count, 0)
    }

    func testReapplyingUnchangedPolicyDoesNotRestartControlCenter() {
        let manager = makeManager()
        manager.applyOnLaunchIfNeeded()
        XCTAssertEqual(restarts.count, 1)

        manager.applyCurrentPolicy()
        manager.setIncludesVolumeInEmblem(true) // already true -> no-op

        XCTAssertEqual(restarts.count, 1)
    }

    // MARK: - Hide Native Icons OFF

    func testHideOffLeavesIconsAloneAndDoesNotRestart() {
        let manager = makeManager(autoHide: false)

        manager.applyOnLaunchIfNeeded()
        manager.restoreOnTerminateIfNeeded()

        assertUserLayoutRestored()
        XCTAssertEqual(restarts.count, 0)
    }

    func testHideOffVolumeBarNoneForceShowsSoundAndGivesBackUserSetting() {
        prefs.host["Sound"] = 8
        prefs.anyHost["NSStatusItem Visible Sound"] = false
        let userSoundHost = prefs.host
        let userSoundAnyHost = prefs.anyHost
        let manager = makeManager(autoHide: false)
        manager.applyOnLaunchIfNeeded()

        manager.setIncludesVolumeInEmblem(false)
        assertForcedVisible("Sound")
        XCTAssertEqual(prefs.host["WiFi"], 2, "Wi-Fi must stay untouched with Hide Native Icons OFF")
        // The forced-Sound snapshot is a separate slot and must not create a main auto-hide snapshot.
        XCTAssertFalse(defaults.bool(forKey: "TrinityBar.hasControlCenterSnapshot"))

        manager.setIncludesVolumeInEmblem(true)
        XCTAssertEqual(prefs.host, userSoundHost)
        XCTAssertEqual(prefs.anyHost, userSoundAnyHost)
    }

    func testQuitWhileSoundIsForceShownGivesBackUserSetting() {
        let manager = makeManager(autoHide: false)
        manager.setIncludesVolumeInEmblem(false, applyImmediately: false)
        manager.applyOnLaunchIfNeeded()
        assertForcedVisible("Sound")

        manager.restoreOnTerminateIfNeeded()

        assertUserLayoutRestored()
    }

    func testTurningHideOnWhileSoundIsForcedSnapshotsRealUserLayout() {
        let manager = makeManager(autoHide: false)
        manager.setIncludesVolumeInEmblem(false)
        assertForcedVisible("Sound")

        manager.autoHideEnabled = true
        manager.restoreOnTerminateIfNeeded()

        // The snapshot must hold the user's own Sound setting (absent), not TrinityBar's forced 18.
        assertUserLayoutRestored()
    }

    // MARK: - Coalesced restarts & write verification

    func testRapidPolicyChangesRestartControlCenterOnce() {
        let scheduler = ManualScheduler()
        let manager = makeManager(scheduler: scheduler)
        manager.applyOnLaunchIfNeeded()
        manager.setIncludesVolumeInEmblem(false)
        manager.setIncludesVolumeInEmblem(true)
        manager.setIncludesVolumeInEmblem(false)
        XCTAssertEqual(restarts.count, 0, "restart must wait for the coalescing delay")
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runAll()

        XCTAssertEqual(restarts.count, 1)
        assertForcedVisible("Sound")
    }

    func testQuitFlushesPendingRestartImmediately() {
        let scheduler = ManualScheduler()
        let manager = makeManager(scheduler: scheduler)
        manager.applyOnLaunchIfNeeded()
        XCTAssertEqual(restarts.count, 0)

        manager.restoreOnTerminateIfNeeded()

        XCTAssertEqual(restarts.count, 1, "quit must apply the restore before the process exits")
        assertUserLayoutRestored()
        scheduler.runAll()
        XCTAssertEqual(restarts.count, 1, "the stale deferred restart must not fire again")
    }

    func testWritesThatDoNotPersistAreReported() {
        prefs.ignoredAnyHostKeys = ["NSStatusItem Visible WiFi"]
        let manager = makeManager()

        manager.applyOnLaunchIfNeeded()

        XCTAssertEqual(manager.lastUnverifiedWrites, ["any:NSStatusItem Visible WiFi"])
    }

    func testPersistedWritesReportNothing() {
        let manager = makeManager()
        manager.applyOnLaunchIfNeeded()
        XCTAssertEqual(manager.lastUnverifiedWrites, [])
    }

    // MARK: - Unverified macOS versions

    func testVerifiedVersionTable() {
        XCTAssertTrue(SystemIconsManager.isVerified(macOSMajor: 26))
        XCTAssertTrue(SystemIconsManager.isVerified(macOSMajor: 27))
        XCTAssertFalse(SystemIconsManager.isVerified(macOSMajor: 28))
        XCTAssertTrue(SystemIconsManager.autoHideAllowedAtLaunch(macOSMajor: 28, confirmedMajor: 28))
        XCTAssertFalse(SystemIconsManager.autoHideAllowedAtLaunch(macOSMajor: 29, confirmedMajor: 28))
    }

    func testFreshInstallOnUnverifiedMacOSLeavesIconsAlone() {
        let manager = makeManager(macOSMajor: 99)
        XCTAssertFalse(manager.isVerifiedOnThisMacOS)
        XCTAssertFalse(manager.autoHideEnabled)

        manager.applyOnLaunchIfNeeded()

        assertUserLayoutRestored()
        XCTAssertEqual(restarts.count, 0)
    }

    func testUpgradeToUnverifiedMacOSWhileHiddenRestoresIcons() {
        let before = makeManager(macOSMajor: 26)
        before.applyOnLaunchIfNeeded()
        assertHidden("WiFi")
        // Simulated macOS upgrade: the app quits without restoring (e.g. killed during the update), then relaunches.

        let after = makeManager(macOSMajor: 99)
        XCTAssertFalse(after.autoHideEnabled)
        after.applyOnLaunchIfNeeded()

        assertUserLayoutRestored()
        // The stored preference itself is kept, so the choice returns once the version is verified.
        XCTAssertTrue(defaults.bool(forKey: "TrinityBar.autoHideSystemIcons.v2"))
    }

    func testOptInOnUnverifiedMacOSIsRememberedForThatVersionOnly() {
        let manager = makeManager(macOSMajor: 99)
        manager.autoHideEnabled = true
        assertHidden("WiFi")
        manager.restoreOnTerminateIfNeeded()

        let relaunched = makeManager(macOSMajor: 99)
        XCTAssertTrue(relaunched.autoHideEnabled, "opt-in persists across launches on the same major version")
        relaunched.restoreOnTerminateIfNeeded()

        let nextMajor = makeManager(macOSMajor: 100)
        XCTAssertFalse(nextMajor.autoHideEnabled, "a newer unverified major version needs a new opt-in")
    }
}
