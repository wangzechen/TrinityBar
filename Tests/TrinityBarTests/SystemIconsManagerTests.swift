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
    func setAnyHostBool(_ value: Bool?, forKey key: String) { anyHost[key] = value }
    func synchronize() { synchronizeCount += 1 }
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

    private func makeManager(autoHide: Bool? = nil) -> SystemIconsManager {
        if let autoHide {
            defaults.set(autoHide, forKey: "TrinityBar.autoHideSystemIcons.v2")
        }
        let counter = restarts!
        return SystemIconsManager(
            defaults: defaults,
            preferences: prefs,
            restartControlCenter: { counter.count += 1 }
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
}
