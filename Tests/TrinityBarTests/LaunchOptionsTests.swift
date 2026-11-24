import XCTest
@testable import TrinityBar

final class LaunchOptionsTests: XCTestCase {
    private let exe = "/Applications/TrinityBar.app/Contents/MacOS/TrinityBar"

    func testNoArgumentsLaunchesApp() {
        XCTAssertEqual(LaunchMode(arguments: [exe]), .app)
        XCTAssertEqual(LaunchMode(arguments: []), .app)
    }

    func testRestoreFlagSelectsRestoreMode() {
        XCTAssertEqual(LaunchMode(arguments: [exe, "--restore-native-icons"]), .restoreNativeIcons)
        XCTAssertEqual(LaunchMode(arguments: [exe, "-NSDocumentRevisionsDebugMode", "YES", "--restore-native-icons"]), .restoreNativeIcons)
    }

    func testUnrelatedOrMisspelledFlagsLaunchApp() {
        XCTAssertEqual(LaunchMode(arguments: [exe, "-psn_0_12345"]), .app)
        XCTAssertEqual(LaunchMode(arguments: [exe, "--restore-native-icon"]), .app)
        XCTAssertEqual(LaunchMode(arguments: [exe, "restore-native-icons"]), .app)
    }

    func testExecutablePathIsNotTreatedAsFlag() {
        XCTAssertEqual(LaunchMode(arguments: ["--restore-native-icons"]), .app)
    }

    func testSingleInstanceDetection() {
        XCTAssertFalse(SingleInstance.anotherInstanceIsRunning(currentPID: 100, runningPIDs: []))
        XCTAssertFalse(SingleInstance.anotherInstanceIsRunning(currentPID: 100, runningPIDs: [100]))
        XCTAssertTrue(SingleInstance.anotherInstanceIsRunning(currentPID: 100, runningPIDs: [100, 200]))
        XCTAssertTrue(SingleInstance.anotherInstanceIsRunning(currentPID: 100, runningPIDs: [200]))
    }
}
