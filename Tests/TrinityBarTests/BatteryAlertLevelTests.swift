import XCTest
@testable import TrinityBar

final class BatteryAlertLevelTests: XCTestCase {
    private func resolve(
        hasBattery: Bool = true,
        percent: Int,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        isLowPowerMode: Bool = false
    ) -> BatteryAlertLevel {
        BatteryAlertLevel.resolve(
            hasBattery: hasBattery,
            percent: percent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            isLowPowerMode: isLowPowerMode
        )
    }

    func testNoBatteryIsAlwaysNormal() {
        XCTAssertEqual(resolve(hasBattery: false, percent: 5), .normal)
        XCTAssertEqual(resolve(hasBattery: false, percent: 5, isCharging: true), .normal)
        XCTAssertEqual(resolve(hasBattery: false, percent: 5, isPluggedIn: true), .normal)
        XCTAssertEqual(resolve(hasBattery: false, percent: 50, isLowPowerMode: true), .normal)
    }

    func testChargingOrPluggedInWinsOverLowLevels() {
        XCTAssertEqual(resolve(percent: 5, isCharging: true), .charging)
        XCTAssertEqual(resolve(percent: 5, isPluggedIn: true), .charging)
        XCTAssertEqual(resolve(percent: 100, isPluggedIn: true, isLowPowerMode: true), .charging)
        XCTAssertEqual(resolve(percent: 80, isCharging: true, isPluggedIn: true), .charging)
    }

    func testThresholdBoundaries() {
        XCTAssertEqual(resolve(percent: 15), .critical)
        XCTAssertEqual(resolve(percent: 16), .low)
        XCTAssertEqual(resolve(percent: 20), .low)
        XCTAssertEqual(resolve(percent: 21), .normal)
        XCTAssertEqual(resolve(percent: 0), .critical)
        XCTAssertEqual(resolve(percent: 100), .normal)
    }

    func testLowPowerMode() {
        XCTAssertEqual(resolve(percent: 80, isLowPowerMode: true), .low)
        XCTAssertEqual(resolve(percent: 21, isLowPowerMode: true), .low)
        // Critical still takes precedence over Low Power Mode.
        XCTAssertEqual(resolve(percent: 15, isLowPowerMode: true), .critical)
    }
}
