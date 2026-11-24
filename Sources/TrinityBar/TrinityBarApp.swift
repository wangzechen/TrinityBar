import AppKit
import QuartzCore
import SwiftUI
import Combine

/// Non-hit-testing overlay image view with `.scaleNone` so `NSButtonCell` never downscales icons taller than 18pt.
private final class UnscaledStatusBarImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Receives `mouseEntered` / `mouseExited` for the status button's tracking area, so scroll monitors exist only
/// while the pointer is over the emblem instead of observing every scroll in every app.
@MainActor
private final class StatusItemHoverTracker: NSResponder {
    var onHoverChange: ((Bool) -> Void)?

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

private struct RenderedStatusIconKey: Equatable {
    let emblem: TrinityEmblemState
    let scale: CGFloat
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var templateImageView: UnscaledStatusBarImageView?
    private var chromaticImageView: UnscaledStatusBarImageView?
    private var panel: StatusFloatingPanel?

    private let settings = AppSettings()
    private let battery = BatteryMonitor()
    private let network = NetworkMonitor()
    private let audio = AudioVolumeMonitor()
    private let caffeinate = CaffeinateManager()
    private let systemIcons = SystemIconsManager(
        // Testing aid: `TRINITYBAR_ASSUME_MACOS_MAJOR=99` exercises the unverified-macOS path on a verified system.
        macOSMajorVersion: ProcessInfo.processInfo.environment["TRINITYBAR_ASSUME_MACOS_MAJOR"].flatMap(Int.init)
            ?? ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
    private var wakeRefreshTask: Task<Void, Never>?
    private var statusBarLocalScrollMonitor: Any?
    private var statusBarGlobalScrollMonitor: Any?
    private let hoverTracker = StatusItemHoverTracker()
    private var isPointerOverStatusItem = false
    /// Volume Bar `None`: after a scroll on the emblem, briefly draw the volume dots as feedback.
    private var showsTransientVolumeFooter = false
    private var transientVolumeFooterTask: Task<Void, Never>?
    private var lastRenderedKey: RenderedStatusIconKey?
    private var lastAccessibilityValue: String?
    private var lastAppearanceName: NSAppearance.Name?
    /// Screenshot mode only: keeps the wallpaper backdrop window alive for the capture.
    private var screenshotBackdrop: NSWindow?
    private var lastPlaceholderSize: CGFloat = 0
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupSignalHandlers()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        if let button = item.button {
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("TrinityBar")

            let baseView = UnscaledStatusBarImageView()
            baseView.imageScaling = .scaleNone
            baseView.setAccessibilityElement(false)
            button.addSubview(baseView)
            self.templateImageView = baseView

            let colorView = UnscaledStatusBarImageView()
            colorView.imageScaling = .scaleNone
            colorView.setAccessibilityElement(false)
            button.addSubview(colorView)
            self.chromaticImageView = colorView

            // AppKit re-posts `effectiveAppearance` KVO whenever the button's subview images are replaced, even
            // though the appearance is unchanged. Re-render only on a real appearance change; otherwise every
            // render would trigger the next one (a 100% CPU main-thread loop).
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new, .initial]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let name = self.statusItem?.button?.effectiveAppearance.name else { return }
                    guard name != self.lastAppearanceName else { return }
                    self.lastAppearanceName = name
                    self.updateStatusIcon(force: true)
                }
            }

            hoverTracker.onHoverChange = { [weak self] isOver in
                self?.isPointerOverStatusItem = isOver
                self?.syncStatusBarScrollMonitors()
            }
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: hoverTracker,
                userInfo: nil
            ))

            boundsObservation = button.observe(\.bounds, options: [.new]) { [weak self] _, change in
                guard let bounds = change.newValue else { return }
                Task { @MainActor [weak self] in
                    self?.centerOverlay(in: bounds)
                }
            }
        }

        let contentView = PopoverDashboardView(
            battery: battery,
            network: network,
            audio: audio,
            caffeinate: caffeinate,
            systemIcons: systemIcons,
            settings: settings,
            onDismissPanel: { [weak self] in
                self?.panel?.dismissPanel()
            }
        )

        let floatingPanel = StatusFloatingPanel(rootView: contentView)
        floatingPanel.onClose = { [weak self] in
            guard let self else { return }
            self.network.setPopoverVisible(false)
            self.battery.setPopoverVisible(false)
            self.caffeinate.isDisplayActive = false
            self.settings.route = .summary
            self.settings.summarySettingsExpanded = false
        }
        floatingPanel.onEscapePressed = { [weak self] in
            guard let self else { return false }
            if self.settings.route != .summary {
                self.settings.route = .summary
                return true
            }
            if self.settings.summarySettingsExpanded {
                self.settings.summarySettingsExpanded = false
                return true
            }
            return false
        }
        floatingPanel.allowsScrollVolume = { [weak self] in
            guard let route = self?.settings.route else { return false }
            return route == .summary || route == .sound
        }
        floatingPanel.onScrollDeltaY = { [weak self] delta in
            self?.audio.adjustVolume(by: Float(delta))
        }
        self.panel = floatingPanel

        systemIcons.setIncludesVolumeInEmblem(settings.bottomMode != .none, applyImmediately: false)
        syncStatusBarScrollMonitors()
        observeWorkspaceWake()
        bindStateChanges()
        updateStatusIcon(force: true)
        systemIcons.applyOnLaunchIfNeeded()
        presentScreenshotSceneIfNeeded()
    }

    /// `scripts/capture_screenshots.sh` support: opens the requested scene and reports panel geometry.
    private func presentScreenshotSceneIfNeeded() {
        guard let scene = ScreenshotMode.scene else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ScreenshotMode.presentDelay)
            guard let self, let panel = self.panel, let button = self.statusItem?.button else { return }
            panel.dismissesOnOutsideClick = false
            panel.horizontalScreenInset = ScreenshotMode.panelEdgeInset
            if let screen = button.window?.screen ?? NSScreen.main {
                let backdrop = ScreenshotMode.makeWallpaperBackdrop(for: screen)
                backdrop.orderFrontRegardless()
                self.screenshotBackdrop = backdrop
            }
            // The status button may not have a window yet (e.g. ControlCenter is still restarting after the previous
            // instance restored native icons), in which case `present(below:)` silently no-ops — retry for ~10 s.
            for _ in 0..<20 where !panel.isVisible {
                if button.window != nil {
                    self.togglePanel(button)
                }
                if panel.isVisible { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.settings.summarySettingsExpanded = (scene == .settings)
            try? await Task.sleep(for: ScreenshotMode.settleDelay)
            guard panel.isVisible, let buttonFrame = self.statusButtonScreenRect() else { return }
            ScreenshotMode.writeGeometry(panelFrame: panel.frame, buttonFrame: buttonFrame)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeRefreshTask?.cancel()
        wakeRefreshTask = nil
        transientVolumeFooterTask?.cancel()
        removeStatusBarScrollMonitors()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        restoreSystemStateBeforeExit()
    }

    /// Releases the keep-awake assertion and restores native Control Center icons (shared by normal quit and SIGTERM / SIGINT).
    private func restoreSystemStateBeforeExit() {
        caffeinate.setKeepAwake(false)
        systemIcons.restoreOnTerminateIfNeeded()
    }

    private func statusButtonScreenRect() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private func handleStatusBarScroll(dy: CGFloat, isPrecise: Bool, mouseLocation: NSPoint) -> Bool {
        guard settings.iconVolumeControl,
              let rect = statusButtonScreenRect(),
              rect.insetBy(dx: -2, dy: -2).contains(mouseLocation) else {
            // Safety net for a missed `mouseExited`: stop observing as soon as a scroll lands elsewhere.
            if isPointerOverStatusItem {
                isPointerOverStatusItem = false
                syncStatusBarScrollMonitors()
            }
            return false
        }
        if let scaled = StatusFloatingPanel.scaledVolumeDelta(dy: dy, isPrecise: isPrecise) {
            audio.adjustVolume(by: Float(scaled))
            flashVolumeFooterIfHidden()
        }
        return true
    }

    private func flashVolumeFooterIfHidden() {
        guard settings.bottomMode == .none else { return }
        showsTransientVolumeFooter = true
        updateStatusIcon(force: false)
        transientVolumeFooterTask?.cancel()
        transientVolumeFooterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.showsTransientVolumeFooter = false
            self.updateStatusIcon(force: false)
        }
    }

    /// Tooltip and help always follow the setting; the scroll monitors themselves are attached only while
    /// Scroll Icon for Volume is on **and** the pointer is over the emblem, so scrolling elsewhere never wakes TrinityBar.
    private func syncStatusBarScrollMonitors() {
        let enabled = settings.iconVolumeControl
        if enabled {
            statusItem?.button?.toolTip = "TrinityBar — Battery, Network & Sound (Scroll: Volume, ⌥-Click: Mute)"
            statusItem?.button?.setAccessibilityHelp("Click to open dashboard, scroll to adjust volume, or Option-click to mute.")
        } else {
            statusItem?.button?.toolTip = "TrinityBar — Battery, Network & Sound"
            statusItem?.button?.setAccessibilityHelp("Click to open dashboard.")
        }
        if enabled && isPointerOverStatusItem {
            statusItem?.button?.toolTip = "TrinityBar — Battery, Network & Sound (Scroll: Volume, ⌥-Click: Mute)"
            statusItem?.button?.setAccessibilityHelp("Click to open dashboard, scroll to adjust volume, or Option-click to mute.")
            if statusBarGlobalScrollMonitor == nil {
                // Global monitor handlers are delivered on the main thread; handle inline so system-wide scrolling
                // elsewhere costs only a rect check instead of a Task hop per event.
                statusBarGlobalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    let dy = event.scrollingDeltaY
                    let isPrecise = event.hasPreciseScrollingDeltas
                    let mouseLoc = NSEvent.mouseLocation
                    MainActor.assumeIsolated {
                        _ = self?.handleStatusBarScroll(dy: dy, isPrecise: isPrecise, mouseLocation: mouseLoc)
                    }
                }
            }
            if statusBarLocalScrollMonitor == nil {
                statusBarLocalScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    let dy = event.scrollingDeltaY
                    let isPrecise = event.hasPreciseScrollingDeltas
                    let mouseLoc = NSEvent.mouseLocation
                    let consumed: Bool = MainActor.assumeIsolated {
                        self?.handleStatusBarScroll(dy: dy, isPrecise: isPrecise, mouseLocation: mouseLoc) ?? false
                    }
                    return consumed ? nil : event
                }
            }
        } else {
            removeStatusBarScrollMonitors()
        }
    }

    private func removeStatusBarScrollMonitors() {
        if let statusBarLocalScrollMonitor {
            NSEvent.removeMonitor(statusBarLocalScrollMonitor)
            self.statusBarLocalScrollMonitor = nil
        }
        if let statusBarGlobalScrollMonitor {
            NSEvent.removeMonitor(statusBarGlobalScrollMonitor)
            self.statusBarGlobalScrollMonitor = nil
        }
    }

    private func observeWorkspaceWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAllMonitorsAfterWake()
            }
        }
    }

    private func refreshAllMonitorsAfterWake() {
        caffeinate.refreshAfterWake()
        battery.refresh()
        network.refreshStaticTelemetry()
        audio.refresh()
        updateStatusIcon(force: true)

        // Follow-up refresh once Wi-Fi DHCP and Bluetooth audio profiles finish reconnecting
        wakeRefreshTask?.cancel()
        wakeRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.battery.refresh()
            self.network.refreshStaticTelemetry()
            self.audio.refresh()
            self.updateStatusIcon(force: true)
            self.wakeRefreshTask = nil
        }
    }

    private func centerOverlay(in buttonBounds: NSRect) {
        let s = AppSettings.fixedIconSize
        let frame = TrinityStatusIconRenderer.contentFrame(in: buttonBounds, contentSize: CGSize(width: s, height: s))
        templateImageView?.frame = frame
        chromaticImageView?.frame = frame
    }

    private func setupSignalHandlers() {
        signalSources = [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.restoreSystemStateBeforeExit()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
    }

    private func bindStateChanges() {
        // Immediate 0ms panel height sync whenever route or disclosure toggles change
        settings.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updateStatusIcon(force: false)
                    if let panel = self.panel, panel.isVisible {
                        panel.syncHeightToContent(animated: true)
                    }
                }
            }
            .store(in: &cancellables)

        // Scan per-process energy only while the Battery page is on screen
        settings.$route
            .removeDuplicates()
            .sink { [weak self] route in
                guard let self else { return }
                self.battery.setEnergyAppsPageVisible(route == .battery && self.panel?.isVisible == true)
            }
            .store(in: &cancellables)

        // Sync native macOS Sound status bar icon visibility whenever Volume Bar switches to/from None
        settings.$bottomMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in
                self?.systemIcons.setIncludesVolumeInEmblem(mode != .none)
            }
            .store(in: &cancellables)

        // Attach or tear down status bar scroll monitors when Scroll Icon for Volume is toggled
        settings.$iconVolumeControl
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // `@Published` fires in willSet; read the new value on the next turn.
                DispatchQueue.main.async { self?.syncStatusBarScrollMonitors() }
            }
            .store(in: &cancellables)

        // Coalesced 20ms sync for background hardware telemetry
        Publishers.Merge3(
            battery.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            network.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            audio.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(20), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.updateStatusIcon(force: false)
            if let panel = self.panel, panel.isVisible {
                DispatchQueue.main.async { [weak self] in
                    self?.panel?.syncHeightToContent(animated: true)
                }
            }
        }
        .store(in: &cancellables)
    }

    private func isButtonDarkAppearance(_ button: NSStatusBarButton) -> Bool {
        let appearance = button.effectiveAppearance
        if let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) {
            return match == .darkAqua || match == .vibrantDark
        }
        return appearance.name.rawValue.localizedCaseInsensitiveContains("dark")
    }

    private func accessibilityStatusSummary() -> String {
        let netText: String = {
            switch network.kind {
            case .wifi: return network.ssid ?? "Wi-Fi"
            case .ethernet: return "Ethernet"
            case .other: return "Connected"
            case .offline: return "Offline"
            }
        }()
        let volText = audio.isMuted ? "Muted"
            : (audio.isVolumeControllable ? "Volume \(audio.volumeLevelText)" : "Volume fixed by device")
        let powerText = battery.hasBattery ? "Battery \(battery.percentage)%" : "AC Power"
        return "\(powerText), \(netText), \(volText)"
    }

    private func updateStatusIcon(force: Bool) {
        guard let button = statusItem?.button else { return }
        let summary = accessibilityStatusSummary()
        if summary != lastAccessibilityValue {
            button.setAccessibilityValue(summary)
            lastAccessibilityValue = summary
        }

        let targetSize = AppSettings.fixedIconSize
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let state = TrinityEmblemState.current(
            battery: battery,
            network: network,
            audio: audio,
            settings: settings,
            isDarkMenuBar: isButtonDarkAppearance(button),
            showsTransientVolumeFooter: showsTransientVolumeFooter
        )

        let key = RenderedStatusIconKey(emblem: state, scale: scale)
        if !force, key == lastRenderedKey {
            return
        }

        // Reserve horizontal menu bar slot with a transparent placeholder image
        if lastPlaceholderSize != targetSize {
            let placeholder = NSImage(size: NSSize(width: targetSize, height: 18))
            button.image = placeholder
            lastPlaceholderSize = targetSize
        }

        if let layers = TrinityStatusIconRenderer.menuBarLayers(
            state: state,
            size: targetSize,
            scale: scale,
            appearance: button.effectiveAppearance
        ) {
            lastRenderedKey = key
            templateImageView?.image = layers.templateBase
            if let overlayCG = layers.chromaticOverlay {
                let colorImg = NSImage(cgImage: overlayCG, size: NSSize(width: targetSize, height: targetSize))
                colorImg.isTemplate = false
                chromaticImageView?.image = colorImg
            } else {
                chromaticImageView?.image = nil
            }
            centerOverlay(in: button.bounds)
        }
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        let currentEvent = NSApp.currentEvent
        let flags = (currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)

        if currentEvent?.type == .rightMouseUp || flags.contains(.control) {
            panel?.dismissPanel()
            let menu = NSMenu()
            let quitItem = NSMenuItem(title: "Quit TrinityBar", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else if settings.iconVolumeControl && flags.contains(.option) {
            audio.toggleMute()
            updateStatusIcon(force: true)
        } else {
            togglePanel(sender)
        }
    }

    private func togglePanel(_ sender: NSStatusBarButton) {
        guard let panel else { return }
        if panel.isVisible {
            panel.dismissPanel()
        } else if !panel.recentlyClosedByOutsideClick {
            settings.route = .summary
            settings.refreshLaunchAtLoginStatus()
            audio.refresh()
            battery.setPopoverVisible(true)
            network.setPopoverVisible(true)
            panel.present(below: sender)
            caffeinate.isDisplayActive = panel.isVisible
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

@main
struct TrinityBarMain {
    @MainActor
    static func main() {
        let mode = LaunchMode(arguments: CommandLine.arguments)
        let otherInstanceRunning = Bundle.main.bundleIdentifier.map { bundleID in
            SingleInstance.anotherInstanceIsRunning(
                currentPID: ProcessInfo.processInfo.processIdentifier,
                runningPIDs: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .map(\.processIdentifier)
            )
        } ?? false

        switch mode {
        case .restoreNativeIcons:
            if otherInstanceRunning {
                // The running instance owns the icons and restores them itself when it quits.
                FileHandle.standardError.write(Data("TrinityBar is running; quit it first (it restores the native icons on quit).\n".utf8))
                exit(1)
            }
            let restored = SystemIconsManager().restoreNativeIconsIfNeeded()
            print(restored ? "Restored the native Wi-Fi, Battery and Sound menu bar icons." : "Nothing to restore: TrinityBar isn't hiding any native icons.")
            exit(0)
        case .app:
            if otherInstanceRunning {
                // Exit before AppDelegate exists: going through NSApp.terminate would run applicationWillTerminate
                // and restore the icons the running instance is hiding.
                exit(0)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
