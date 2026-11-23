import AppKit
import XCTest
@testable import TrinityBar

@MainActor
final class TrinityStatusIconRendererTests: XCTestCase {
    private func state(
        percent: Int = 80,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        isLowPowerMode: Bool = false,
        kind: ConnectionKind = .wifi,
        mode: BottomIndicatorMode = .volumeDots
    ) -> TrinityEmblemState {
        TrinityEmblemState(
            hasBattery: true,
            batteryPercent: percent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            isLowPowerMode: isLowPowerMode,
            showTopPercentage: true,
            connectionKind: kind,
            wifiStrengthBars: 2,
            bottomMode: mode,
            bottomDots: 3,
            bottomProgress: 0.6,
            isDarkMenuBar: false
        )
    }

    private func layers(_ state: TrinityEmblemState) -> TrinityStatusIconRenderer.MenuBarLayers? {
        TrinityStatusIconRenderer.menuBarLayers(state: state, size: 24, scale: 2, appearance: NSAppearance(named: .aqua))
    }

    func testRendersEveryModeConnectionAndChargingCombination() throws {
        for mode in BottomIndicatorMode.allCases {
            for kind in [ConnectionKind.wifi, .ethernet, .offline] {
                for charging in [false, true] {
                    let label = "\(mode) \(kind) charging=\(charging)"
                    let result = try XCTUnwrap(layers(state(isCharging: charging, kind: kind, mode: mode)), label)
                    XCTAssertTrue(result.templateBase.isTemplate, label)
                    XCTAssertEqual(result.chromaticOverlay != nil, charging, label)
                }
            }
        }
    }

    func testChromaticOverlayOnlyForAlertStates() throws {
        XCTAssertNil(try XCTUnwrap(layers(state(percent: 80))).chromaticOverlay)
        XCTAssertNil(try XCTUnwrap(layers(state(percent: 21))).chromaticOverlay)
        XCTAssertNotNil(try XCTUnwrap(layers(state(percent: 80, isCharging: true))).chromaticOverlay)
        XCTAssertNotNil(try XCTUnwrap(layers(state(percent: 80, isPluggedIn: true))).chromaticOverlay)
        XCTAssertNotNil(try XCTUnwrap(layers(state(percent: 20))).chromaticOverlay)
        XCTAssertNotNil(try XCTUnwrap(layers(state(percent: 10))).chromaticOverlay)
        XCTAssertNotNil(try XCTUnwrap(layers(state(percent: 80, isLowPowerMode: true))).chromaticOverlay)
    }

    func testInvalidSizeReturnsNil() {
        XCTAssertNil(TrinityStatusIconRenderer.menuBarLayers(state: state(), size: 0, scale: 2, appearance: nil))
        XCTAssertNil(TrinityStatusIconRenderer.menuBarLayers(state: state(), size: 24, scale: 0, appearance: nil))
    }

    func testContentFrameIsCentered() {
        let bounds = CGRect(x: 0, y: 0, width: 30, height: 22)
        let result = TrinityStatusIconRenderer.contentFrame(in: bounds, contentSize: CGSize(width: 24, height: 24))
        XCTAssertEqual(result, CGRect(x: 3, y: -1, width: 24, height: 24))
    }
}
