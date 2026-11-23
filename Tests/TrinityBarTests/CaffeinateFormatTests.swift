import XCTest
@testable import TrinityBar

final class CaffeinateFormatTests: XCTestCase {
    func testUnderAnHourUsesMinutesAndSeconds() {
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 0), "0:00")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 1), "0:01")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 59), "0:59")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 60), "1:00")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 61), "1:01")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 1799), "29:59")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 1800), "30:00")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 3599), "59:59")
    }

    func testAnHourOrMoreUsesHoursMinutesSeconds() {
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 3600), "1:00:00")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 3601), "1:00:01")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 5399), "1:29:59")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 5400), "1:30:00")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 7200), "2:00:00")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 36000), "10:00:00")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: -5), "0:00")
    }
}
