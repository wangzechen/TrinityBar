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

    // MARK: - Charge hold reason

    private func acDesc(charging: Bool, extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = [
            kIOPSPowerSourceStateKey as String: kIOPSACPowerValue as String,
            kIOPSIsChargingKey as String: charging,
        ]
        d.merge(extra) { $1 }
        return d
    }

    func testNoHoldWhileChargingOrOnBattery() {
        XCTAssertNil(BatteryMonitor.chargeHoldReason(description: acDesc(charging: true)))
        XCTAssertNil(BatteryMonitor.chargeHoldReason(description: [
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue as String,
            kIOPSIsChargingKey as String: false,
        ]))
    }

    func testChargedOptimizedAndGenericHold() {
        XCTAssertEqual(BatteryMonitor.chargeHoldReason(description: acDesc(charging: false, extra: [kIOPSIsChargedKey as String: true])), .charged)
        XCTAssertEqual(BatteryMonitor.chargeHoldReason(description: acDesc(charging: false, extra: ["Optimized Battery Charging Engaged": true])), .optimized)
        XCTAssertEqual(BatteryMonitor.chargeHoldReason(description: acDesc(charging: false)), .onHold)
    }

    func testOptimizedWinsOverCharged() {
        let d = acDesc(charging: false, extra: [kIOPSIsChargedKey as String: true, "Optimized Battery Charging Engaged": true])
        XCTAssertEqual(BatteryMonitor.chargeHoldReason(description: d), .optimized)
    }

    // MARK: - Battery temperature

    func testTemperatureIsCentiCelsius() {
        XCTAssertEqual(BatteryMonitor.batteryTemperatureCelsius(raw: 3120)!, 31.2, accuracy: 1e-9)
        XCTAssertNil(BatteryMonitor.batteryTemperatureCelsius(raw: 0))
        XCTAssertNil(BatteryMonitor.batteryTemperatureCelsius(raw: 9_000))
    }
}
