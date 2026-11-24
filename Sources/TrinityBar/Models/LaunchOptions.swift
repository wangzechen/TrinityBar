import Foundation

/// What a process launch should do, decided before `NSApplication` starts.
enum LaunchMode: Equatable, Sendable {
    /// Normal menu bar app.
    case app
    /// `--restore-native-icons`: hand the native Wi-Fi / Battery / Sound icons back to the user's own
    /// Control Center settings and exit without showing UI. Used by the uninstall steps and after a
    /// crash or `SIGKILL` left the icons hidden.
    case restoreNativeIcons

    static let restoreNativeIconsFlag = "--restore-native-icons"

    init(arguments: [String]) {
        // arguments[0] is the executable path; macOS may also pass `-psn_…` / `-NSDocumentRevisionsDebugMode` style flags.
        self = arguments.dropFirst().contains(Self.restoreNativeIconsFlag) ? .restoreNativeIcons : .app
    }
}

enum SingleInstance {
    /// `true` when another process with the same bundle identifier is already running, so this launch must
    /// exit before touching any state. Two instances would share (and fight over) the native-icon snapshot.
    static func anotherInstanceIsRunning(currentPID: pid_t, runningPIDs: [pid_t]) -> Bool {
        runningPIDs.contains { $0 != currentPID }
    }
}
