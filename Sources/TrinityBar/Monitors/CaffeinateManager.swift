import Foundation
import IOKit.pwr_mgt
import os

enum CaffeinateDuration: Int, CaseIterable, Identifiable, Sendable {
    case minutes30 = 1800
    case hours1 = 3600
    case hours2 = 7200
    case indefinite = 0

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .minutes30: return "30m"
        case .hours1: return "1h"
        case .hours2: return "2h"
        case .indefinite: return "∞"
        }
    }
}

@MainActor
final class CaffeinateManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.zechen.trinitybar", category: "Caffeinate")
    private static let durationDefaultsKey = "TrinityBar.keepAwakeDuration"

    @Published private(set) var isKeepingAwake: Bool = false
    @Published private(set) var selectedDuration: CaffeinateDuration
    @Published private(set) var remainingBadgeText: String?

    nonisolated(unsafe) private var assertionID: IOPMAssertionID = 0
    nonisolated(unsafe) private var countdownTimer: Timer?
    private var expiresAt: Date?

    init() {
        let savedRaw = UserDefaults.standard.object(forKey: Self.durationDefaultsKey) as? Int
        self.selectedDuration = savedRaw.flatMap(CaffeinateDuration.init(rawValue:)) ?? .indefinite
    }

    deinit {
        countdownTimer?.invalidate()
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    func toggle() {
        setKeepAwake(!isKeepingAwake)
    }

    func activate(duration: CaffeinateDuration) {
        selectedDuration = duration
        UserDefaults.standard.set(duration.rawValue, forKey: Self.durationDefaultsKey)
        if !isKeepingAwake {
            setKeepAwake(true)
        } else {
            configureTimer(for: duration)
        }
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
                configureTimer(for: selectedDuration)
            } else {
                Self.logger.error("IOPMAssertionCreateWithName failed with status \(result, privacy: .public)")
            }
        } else {
            clearTimer()
            if assertionID != 0 {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
            }
            isKeepingAwake = false
        }
    }

    func refreshAfterWake() {
        handleCountdownTick()
    }

    private func configureTimer(for duration: CaffeinateDuration) {
        clearTimer()
        guard duration != .indefinite else { return }

        let target = Date().addingTimeInterval(TimeInterval(duration.rawValue))
        expiresAt = target
        updateCountdownDisplay(remaining: target.timeIntervalSinceNow)

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleCountdownTick()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func clearTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        expiresAt = nil
        if remainingBadgeText != nil {
            remainingBadgeText = nil
        }
    }

    private func handleCountdownTick() {
        guard isKeepingAwake, let expiresAt else {
            clearTimer()
            return
        }
        let remaining = expiresAt.timeIntervalSinceNow
        if remaining <= 0 {
            setKeepAwake(false)
            return
        }
        updateCountdownDisplay(remaining: remaining)
    }

    private func updateCountdownDisplay(remaining: TimeInterval) {
        let secs = max(1, Int(ceil(remaining)))
        let formatted = Self.formatRemaining(seconds: secs)
        if remainingBadgeText != formatted {
            remainingBadgeText = formatted
        }
    }

    private static func formatRemaining(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let totalMinutes = (seconds + 59) / 60
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours > 0 {
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
        return "\(mins)m"
    }
}
