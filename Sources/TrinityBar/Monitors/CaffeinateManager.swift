import Foundation
import IOKit.pwr_mgt
import os

@MainActor
final class CaffeinateManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.zechen.trinitybar", category: "Caffeinate")

    @Published private(set) var isKeepingAwake: Bool = false
    private var assertionID: IOPMAssertionID = 0

    func toggle() {
        setKeepAwake(!isKeepingAwake)
    }

    func setKeepAwake(_ enabled: Bool) {
        guard enabled != isKeepingAwake else { return }

        if enabled {
            let reason = "TrinityBar: Keep Mac Awake" as CFString
            let assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                assertionType,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &newID
            )
            if result == kIOReturnSuccess {
                assertionID = newID
                isKeepingAwake = true
            } else {
                Self.logger.error("IOPMAssertionCreateWithName failed with status \(result, privacy: .public)")
            }
        } else {
            if assertionID != 0 {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
            }
            isKeepingAwake = false
        }
    }
}
