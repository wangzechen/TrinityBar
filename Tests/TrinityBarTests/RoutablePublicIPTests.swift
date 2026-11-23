import XCTest
@testable import TrinityBar

final class RoutablePublicIPTests: XCTestCase {
    private func isPublic(_ ip: String) -> Bool {
        NetworkMonitor.isRoutablePublicIP(ip)
    }

    func testPrivateAndSpecialIPv4AreRejected() {
        let rejected = [
            "10.0.0.1", "10.255.255.255",
            "172.16.0.1", "172.20.1.1", "172.31.255.255",
            "192.168.1.1",
            "127.0.0.1",
            "169.254.10.20",
            "100.64.0.1", "100.100.100.100", "100.127.255.255",
            "198.18.0.1", "198.19.255.254",
            "0.0.0.0",
        ]
        for ip in rejected {
            XCTAssertFalse(isPublic(ip), ip)
        }
    }

    func testNeighboursOfPrivateRangesAreAccepted() {
        for ip in ["172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "198.17.0.1", "198.20.0.1"] {
            XCTAssertTrue(isPublic(ip), ip)
        }
    }

    func testSpecialIPv6AreRejected() {
        for ip in ["::1", "fe80::1", "FE80::abcd", "fd00::1", "fc00::1"] {
            XCTAssertFalse(isPublic(ip), ip)
        }
    }

    func testPublicAddressesAreAccepted() {
        for ip in ["1.1.1.1", "8.8.8.8", "2606:4700::1111"] {
            XCTAssertTrue(isPublic(ip), ip)
        }
    }

    func testMalformedAddressesAreRejected() {
        for ip in ["", "not-an-ip", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-4", "a.b.c.d"] {
            XCTAssertFalse(isPublic(ip), ip)
        }
    }
}
