import AppKit
import QuartzCore
import SwiftUI

/// Flipped container so `(0, 0)` is the top-left corner of the panel; prevents `NSHostingView` from shifting/centering content vertically while the panel animates its height.
private final class TopPinnedContainerView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class StatusFloatingPanel: NSPanel {
    static let cornerRadius: CGFloat = 16
    static let menuBarGap: CGFloat = 6
    static let screenMargin: CGFloat = 8

    static func scaledVolumeDelta(dy: CGFloat, isPrecise: Bool) -> CGFloat? {
        guard abs(dy) > 0.05 else { return nil }
        let raw = isPrecise ? dy * 0.0003 : dy * 0.01
        return min(0.08, max(-0.08, raw))
    }

    var onClose: (() -> Void)?
    var onScrollDeltaY: ((CGFloat) -> Void)?
    var onEscapePressed: (() -> Bool)?
    var allowsScrollVolume: (() -> Bool)?

    private static let permanentHostingCanvasHeight: CGFloat = 1600
    private let rootContainer: NSView
    private let topPinnedContainer: TopPinnedContainerView
    private var backdropView: NSView?
    private var currentReduceTransparency: Bool = false
    nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?
    private var hostingView: NSView?
    nonisolated(unsafe) private var globalClickMonitor: Any?
    nonisolated(unsafe) private var localKeyMonitor: Any?
    nonisolated(unsafe) private var localScrollMonitor: Any?
    private var anchorButtonScreenRect: NSRect = .zero
    private var lastCloseTimestamp: TimeInterval = 0

    var recentlyClosedByOutsideClick: Bool {
        ProcessInfo.processInfo.systemUptime - lastCloseTimestamp < 0.25
    }

    init<Content: View>(rootView: Content) {
        let initialBounds = NSRect(x: 0, y: 0, width: 332, height: 300)
        self.rootContainer = NSView(frame: initialBounds)
        self.topPinnedContainer = TopPinnedContainerView(frame: initialBounds)

        super.init(
            contentRect: initialBounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isMovable = false
        isMovableByWindowBackground = false
        title = "TrinityBar"
        setAccessibilityRole(.popover)
        setAccessibilityLabel("TrinityBar Dashboard")

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = .intrinsicContentSize
        self.hostingView = hosting.view

        rootContainer.wantsLayer = true
        rootContainer.layer?.cornerRadius = Self.cornerRadius
        rootContainer.layer?.masksToBounds = true

        topPinnedContainer.autoresizingMask = [.width, .height]
        hosting.view.frame = NSRect(x: 0, y: 0, width: 332, height: Self.permanentHostingCanvasHeight)
        hosting.view.autoresizingMask = [.width]
        topPinnedContainer.addSubview(hosting.view)

        rebuildBackdrop(force: true)

        let wrapperVC = NSViewController()
        wrapperVC.view = rootContainer
        wrapperVC.addChild(hosting)
        self.contentViewController = wrapperVC

        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildBackdrop(force: false)
            }
        }
    }

    deinit {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    private func rebuildBackdrop(force: Bool) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard force || reduceTransparency != currentReduceTransparency else { return }
        currentReduceTransparency = reduceTransparency

        if #available(macOS 26.0, *), let glass = backdropView as? NSGlassEffectView {
            glass.contentView = nil
        }
        topPinnedContainer.removeFromSuperview()
        backdropView?.removeFromSuperview()
        backdropView = nil

        let bounds = rootContainer.bounds
        topPinnedContainer.translatesAutoresizingMaskIntoConstraints = true
        topPinnedContainer.autoresizingMask = [.width, .height]
        topPinnedContainer.frame = bounds

        if reduceTransparency {
            let solid = NSBox(frame: bounds)
            solid.boxType = .custom
            solid.isTransparent = false
            solid.fillColor = .windowBackgroundColor
            solid.borderWidth = 0
            solid.cornerRadius = Self.cornerRadius
            solid.autoresizingMask = [.width, .height]
            rootContainer.addSubview(solid)
            rootContainer.addSubview(topPinnedContainer)
            backdropView = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.autoresizingMask = [.width, .height]
            glass.contentView = topPinnedContainer
            rootContainer.addSubview(glass)
            backdropView = glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            rootContainer.addSubview(effect)
            rootContainer.addSubview(topPinnedContainer)
            backdropView = effect
        }

        if isVisible {
            invalidateShadow()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(rectInWindow)
        self.anchorButtonScreenRect = screenRect

        rebuildBackdrop(force: false)
        applyFittingFrame(animated: false)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
            orderFrontRegardless()
            makeKey()
            invalidateShadow()
        } else {
            alphaValue = 0
            orderFrontRegardless()
            makeKey()
            invalidateShadow()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                self.animator().alphaValue = 1
            }
        }

        NSAccessibility.post(element: self, notification: .focusedWindowChanged)
        installEventMonitors()
    }

    func syncHeightToContent(animated: Bool = true) {
        guard isVisible, anchorButtonScreenRect != .zero else { return }
        applyFittingFrame(animated: animated)
    }

    private func applyFittingFrame(animated: Bool) {
        guard let hosting = hostingView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let targetWidth: CGFloat = 332
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorButtonScreenRect) }) ?? NSScreen.main
        let maxAvailHeight = max(240, (anchorButtonScreenRect.minY - (screen?.visibleFrame.minY ?? 0)) - Self.menuBarGap - Self.screenMargin - 8)
        let targetHeight = min(maxAvailHeight, max(160, ceil(fitting.height)))
        let panelSize = NSSize(width: targetWidth, height: targetHeight)
        let targetFrame = Self.computePanelFrame(panelSize: panelSize, anchorScreenRect: anchorButtonScreenRect)

        // Keep hosting canvas permanently taller than any route/drawer so NSHostingView never vertically centers on frame 0 before window resize begins
        if hosting.frame.height != Self.permanentHostingCanvasHeight || hosting.frame.origin != .zero {
            hosting.frame = NSRect(x: 0, y: 0, width: targetWidth, height: Self.permanentHostingCanvasHeight)
        }

        let shouldAnimate = animated && isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if abs(frame.height - targetFrame.height) > 0.5 || abs(frame.minX - targetFrame.minX) > 0.5 || abs(frame.minY - targetFrame.minY) > 0.5 {
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    self.animator().setFrame(targetFrame, display: true)
                }, completionHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.invalidateShadow()
                    }
                })
            } else {
                setFrame(targetFrame, display: true)
                invalidateShadow()
            }
        }
    }

    func dismissPanel(fromOutsideClick: Bool = false) {
        guard isVisible else { return }
        if fromOutsideClick {
            lastCloseTimestamp = ProcessInfo.processInfo.systemUptime
        }
        removeEventMonitors()
        orderOut(nil)
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        handleEscape()
    }

    /// Escape pops a drill-down route / collapses the drawer first; dismisses only from the bare summary.
    private func handleEscape() {
        if onEscapePressed?() == true {
            return
        }
        dismissPanel()
    }

    private static func computePanelFrame(panelSize: NSSize, anchorScreenRect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorScreenRect) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchorScreenRect.midX - panelSize.width / 2.0
        x = min(max(x, visible.minX + screenMargin), visible.maxX - panelSize.width - screenMargin)

        // Screen coordinates always have Y pointing UP: anchorScreenRect.minY is the exact bottom edge of the menu bar button!
        var y = anchorScreenRect.minY - menuBarGap - panelSize.height
        y = max(y, visible.minY + screenMargin)

        return NSRect(x: round(x), y: round(y), width: panelSize.width, height: panelSize.height)
    }

    private func installEventMonitors() {
        removeEventMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let mouseLoc = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                // Let the status bar button handle its own click toggle
                if self.anchorButtonScreenRect.insetBy(dx: -4, dy: -4).contains(mouseLoc) {
                    return
                }
                if !self.frame.contains(mouseLoc) {
                    self.dismissPanel(fromOutsideClick: true)
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated {
                    self?.handleEscape()
                }
                return nil
            }
            return event
        }

        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self else { return }
                let dy = event.scrollingDeltaY
                if let scaled = Self.scaledVolumeDelta(dy: dy, isPrecise: event.hasPreciseScrollingDeltas),
                   self.allowsScrollVolume?() ?? true {
                    self.onScrollDeltaY?(scaled)
                }
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
    }
}
