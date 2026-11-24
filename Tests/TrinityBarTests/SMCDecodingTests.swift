import XCTest
@testable import TrinityBar

/// Drives the AppleSMC struct decoding with a fake `IOConnectCallStructMethod` exchange.
final class SMCDecodingTests: XCTestCase {
    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Answers a key-info request (selector 9) with `type`/`size`, and a read (selector 5) with `data` at offset 48.
    private func fakeExchange(type: String, size: UInt32, data: [UInt8], result: UInt8 = 0) -> ([UInt8]) -> [UInt8]? {
        let typeCode = fourCC(type)
        return { req in
            var resp = [UInt8](repeating: 0, count: 80)
            resp[40] = result
            switch req[42] {
            case 9:
                for i in 0..<4 {
                    resp[28 + i] = UInt8(truncatingIfNeeded: size >> (i * 8))
                    resp[32 + i] = UInt8(truncatingIfNeeded: typeCode >> (i * 8))
                }
            case 5:
                resp.replaceSubrange(48..<(48 + data.count), with: data)
            default:
                return nil
            }
            return resp
        }
    }

    func testFloatScalar() {
        let bits = Float(12.5).bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        let v = BatteryMonitor.readSMCScalar(key: fourCC("PSTR"), exchange: fakeExchange(type: "flt ", size: 4, data: bytes))
        XCTAssertEqual(v, 12.5)
    }

    func testFixedPointScalars() {
        // fpe2: unsigned big-endian, 2 fractional bits -> 0x0019 / 4 = 6.25
        XCTAssertEqual(BatteryMonitor.readSMCScalar(key: 0, exchange: fakeExchange(type: "fpe2", size: 2, data: [0x00, 0x19])), 6.25)
        // sp78: signed big-endian, 8 fractional bits -> 0xFF80 = -128 / 256 = -0.5
        XCTAssertEqual(BatteryMonitor.readSMCScalar(key: 0, exchange: fakeExchange(type: "sp78", size: 2, data: [0xFF, 0x80])), -0.5)
    }

    func testUnknownTypeOrSmcErrorReturnsNil() {
        XCTAssertNil(BatteryMonitor.readSMCScalar(key: 0, exchange: fakeExchange(type: "ui8 ", size: 1, data: [7])))
        XCTAssertNil(BatteryMonitor.readSMCScalar(key: 0, exchange: fakeExchange(type: "flt ", size: 4, data: [0, 0, 0, 0], result: 0x84)))
    }

    func testNonFiniteFloatIsDropped() {
        let bits = Float.nan.bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        XCTAssertNil(BatteryMonitor.readSMCScalar(key: 0, exchange: fakeExchange(type: "flt ", size: 4, data: bytes)))
    }

    func testIntegerSensorsAreLittleEndianMilliUnits() {
        // ui16 12_345 mV -> 12.345 V
        XCTAssertEqual(
            BatteryMonitor.readSMCIntegerSensor(key: 0, signed: false, exchange: fakeExchange(type: "ui16", size: 2, data: [0x39, 0x30]))!,
            12.345, accuracy: 1e-9
        )
        // si16 -1_500 mA -> -1.5 A
        XCTAssertEqual(
            BatteryMonitor.readSMCIntegerSensor(key: 0, signed: true, exchange: fakeExchange(type: "si16", size: 2, data: [0x24, 0xFA]))!,
            -1.5, accuracy: 1e-9
        )
        XCTAssertNil(BatteryMonitor.readSMCIntegerSensor(key: 0, signed: false, exchange: fakeExchange(type: "flt ", size: 4, data: [0, 0, 0, 0])))
    }
}
