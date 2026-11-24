import IOKit.ps
import XCTest
@testable import TrinityBar

final class PowerSourceSelectionTests: XCTestCase {
    private let internalType = kIOPSInternalBatteryType as String
    private let upsType = kIOPSUPSType as String
    private let typeKey = kIOPSTypeKey as String
    private let presentKey = kIOPSIsPresentKey as String
    private let nameKey = kIOPSNameKey as String

    private func internalBattery(present: Bool? = true) -> [String: Any] {
        var desc: [String: Any] = [typeKey: internalType, nameKey: "InternalBattery-0", kIOPSCurrentCapacityKey as String: 80]
        if let present { desc[presentKey] = present }
        return desc
    }

    private func ups() -> [String: Any] {
        [typeKey: upsType, nameKey: "Back-UPS", presentKey: true, kIOPSCurrentCapacityKey as String: 15]
    }

    private func selectedName(_ list: [[String: Any]]) -> String? {
        BatteryMonitor.selectInternalBattery(list)?[nameKey] as? String
    }

    func testEmptyListMeansNoBattery() {
        XCTAssertNil(BatteryMonitor.selectInternalBattery([]))
    }

    func testUPSOnlyDesktopMeansNoBattery() {
        XCTAssertNil(BatteryMonitor.selectInternalBattery([ups()]))
    }

    func testInternalBatteryIsChosenEvenWhenUPSIsListedFirst() {
        XCTAssertEqual(selectedName([ups(), internalBattery()]), "InternalBattery-0")
        XCTAssertEqual(selectedName([internalBattery(), ups()]), "InternalBattery-0")
    }

    func testBatteryReportedAsNotPresentIsIgnored() {
        XCTAssertNil(BatteryMonitor.selectInternalBattery([internalBattery(present: false)]))
        XCTAssertNil(BatteryMonitor.selectInternalBattery([ups(), internalBattery(present: false)]))
    }

    func testMissingPresentFlagCountsAsPresent() {
        XCTAssertEqual(selectedName([internalBattery(present: nil)]), "InternalBattery-0")
    }

    func testUntypedSourceIsIgnored() {
        XCTAssertNil(BatteryMonitor.selectInternalBattery([[nameKey: "Mystery", kIOPSCurrentCapacityKey as String: 50]]))
    }
}
