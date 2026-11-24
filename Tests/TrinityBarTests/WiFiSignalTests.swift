import XCTest
@testable import TrinityBar

final class WiFiSignalTests: XCTestCase {
    func testBarBoundaries() {
        XCTAssertEqual(WiFiSignal.bars(rssi: -40), 3)
        XCTAssertEqual(WiFiSignal.bars(rssi: -70), 3)
        XCTAssertEqual(WiFiSignal.bars(rssi: -71), 2)
        XCTAssertEqual(WiFiSignal.bars(rssi: -78), 2)
        XCTAssertEqual(WiFiSignal.bars(rssi: -79), 1)
        XCTAssertEqual(WiFiSignal.bars(rssi: -88), 1)
        XCTAssertEqual(WiFiSignal.bars(rssi: -89), 0)
        XCTAssertEqual(WiFiSignal.bars(rssi: -100), 0)
    }

    func testVariableValueMapping() {
        XCTAssertEqual(WiFiSignal.variableValue(bars: 0), 0.0)
        XCTAssertEqual(WiFiSignal.variableValue(bars: 1), 0.33)
        XCTAssertEqual(WiFiSignal.variableValue(bars: 2), 0.66)
        XCTAssertEqual(WiFiSignal.variableValue(bars: 3), 1.0)
        XCTAssertEqual(WiFiSignal.variableValue(bars: 4), 1.0)
        XCTAssertEqual(WiFiSignal.variableValue(bars: -1), 0.0)
    }

    func testBackgroundSignalTimerOnlyOnWiFiWithPanelClosed() {
        XCTAssertTrue(NetworkMonitor.needsBackgroundSignalTimer(kind: .wifi, isPopoverVisible: false))
        XCTAssertFalse(NetworkMonitor.needsBackgroundSignalTimer(kind: .wifi, isPopoverVisible: true))
        XCTAssertFalse(NetworkMonitor.needsBackgroundSignalTimer(kind: .ethernet, isPopoverVisible: false))
        XCTAssertFalse(NetworkMonitor.needsBackgroundSignalTimer(kind: .offline, isPopoverVisible: false))
        XCTAssertFalse(NetworkMonitor.needsBackgroundSignalTimer(kind: .other, isPopoverVisible: false))
    }
}
