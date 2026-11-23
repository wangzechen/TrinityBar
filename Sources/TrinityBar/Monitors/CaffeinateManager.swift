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

    /// True while the dashboard panel is on screen. The countdown then ticks every second;
    /// otherwise it refreshes about once a minute so a long session doesn't wake the app every second.
    /// Expiry is always scheduled from `expiresAt`, so it fires on time either way.
    var isDisplayActive: Bool = false {
        didSet {
            guard isDisplayActive != oldValue else { return }
            if isDisplayActive {
                handleCountdownTick()
            } else if isKeepingAwake, let expiresAt {
                scheduleNextTick(remaining: expiresAt.timeIntervalSinceNow)
            }
        }
    }

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
        let remaining = target.timeIntervalSinceNow
        updateCountdownDisplay(remaining: remaining)
        scheduleNextTick(remaining: remaining)
    }

    private func scheduleNextTick(remaining: TimeInterval) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard isKeepingAwake, remaining > 0 else { return }

        let perSecond = isDisplayActive || remaining <= 60.0
        let interval: TimeInterval
        if perSecond {
            // Land just past the next whole-second boundary so ceil(remaining) has stepped down.
            let frac = remaining - floor(remaining)
            let toBoundary = frac > 0.02 ? frac + 0.01 : 1.01
            interval = min(toBoundary, remaining)
        } else {
            let mod = remaining.truncatingRemainder(dividingBy: 60.0)
            let toBoundary = mod > 0.25 ? mod : 60.0
            interval = max(1.0, min(toBoundary, remaining - 59.5))
        }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleCountdownTick()
            }
        }
        timer.tolerance = perSecond ? 0.05 : min(1.0, interval * 0.1)
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
        scheduleNextTick(remaining: remaining)
    }

    private func updateCountdownDisplay(remaining: TimeInterval) {
        let secs = max(1, Int(ceil(remaining)))
        let formatted = Self.formatRemaining(seconds: secs)
        if remainingBadgeText != formatted {
            remainingBadgeText = formatted
        }
    }

    /// Clock-style countdown: `H:MM:SS` with at least an hour left, otherwise `M:SS`.
    nonisolated static func formatRemaining(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        let ss = secs < 10 ? "0\(secs)" : "\(secs)"
        if hours > 0 {
            let mm = mins < 10 ? "0\(mins)" : "\(mins)"
            return "\(hours):\(mm):\(ss)"
        }
        return "\(mins):\(ss)"
    }
}
