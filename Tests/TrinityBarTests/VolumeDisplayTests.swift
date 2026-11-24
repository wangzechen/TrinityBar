import XCTest
@testable import TrinityBar

final class VolumeDisplayTests: XCTestCase {
    private func dots(_ volume: Float, muted: Bool = false, controllable: Bool = true) -> Int {
        AudioVolumeMonitor.volumeDots(volume: volume, isMuted: muted, isVolumeControllable: controllable)
    }

    private func progress(_ volume: Float, muted: Bool = false, controllable: Bool = true) -> Double {
        AudioVolumeMonitor.effectiveProgress(volume: volume, isMuted: muted, isVolumeControllable: controllable)
    }

    private func text(_ volume: Float, muted: Bool = false, controllable: Bool = true) -> String {
        AudioVolumeMonitor.volumeLevelText(volume: volume, isMuted: muted, isVolumeControllable: controllable)
    }

    func testDotThresholds() {
        XCTAssertEqual(dots(0.0), 0)
        XCTAssertEqual(dots(0.01), 0)
        XCTAssertEqual(dots(0.02), 1)
        XCTAssertEqual(dots(0.27), 1)
        XCTAssertEqual(dots(0.28), 2)
        XCTAssertEqual(dots(0.52), 2)
        XCTAssertEqual(dots(0.53), 3)
        XCTAssertEqual(dots(0.77), 3)
        XCTAssertEqual(dots(0.78), 4)
        XCTAssertEqual(dots(1.0), 4)
    }

    func testMutedShowsNoLevel() {
        XCTAssertEqual(dots(0.9, muted: true), 0)
        XCTAssertEqual(progress(0.9, muted: true), 0.0)
        XCTAssertEqual(text(0.9, muted: true), "Muted")
    }

    func testNonControllableOutputShowsNoStaleLevel() {
        // e.g. switched from speakers at 90% to an HDMI display: the old 0.9 must not be shown.
        XCTAssertEqual(dots(0.9, controllable: false), 0)
        XCTAssertEqual(progress(0.9, controllable: false), 0.0)
        XCTAssertEqual(text(0.9, controllable: false), "—")
    }

    func testMutedNonControllableOutputStillReportsMuted() {
        XCTAssertEqual(text(0.9, muted: true, controllable: false), "Muted")
    }

    func testControllableLevelText() {
        XCTAssertEqual(text(0.0), "0%")
        XCTAssertEqual(text(0.454), "45%")
        XCTAssertEqual(text(0.455), "46%")
        XCTAssertEqual(text(1.0), "100%")
        XCTAssertEqual(text(1.2), "100%")
    }

    func testProgressIsClamped() {
        XCTAssertEqual(progress(0.6), 0.6, accuracy: 1e-6)
        XCTAssertEqual(progress(1.4), 1.0)
        XCTAssertEqual(progress(-0.2), 0.0)
    }
}
