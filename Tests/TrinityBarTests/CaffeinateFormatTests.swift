import XCTest
@testable import TrinityBar

final class CaffeinateFormatTests: XCTestCase {
    func testFormatRemaining() {
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 1), "1s")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 59), "59s")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 60), "1m")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 61), "2m") // rounds up
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 3599), "1h")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 3600), "1h")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 3601), "1h 1m")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 5400), "1h 30m")
        XCTAssertEqual(CaffeinateManager.formatRemaining(seconds: 7200), "2h")
    }
}
