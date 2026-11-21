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

    var onClose: (() -> Void)?
    var onScrollDeltaY: ((CGFloat) -> Void)?
    var onEscapePressed: (() -> Bool)?
    var allowsScrollVolume: (() -> Bool)?

    private static let permanentHostingCanvasHeight: CGFloat = 1600
    private var hostingView: NSView?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var localScrollMonitor: Any?
    private var anchorButtonScreenRect: NSRect = .zero
    private var lastCloseTimestamp: TimeInterval = 0

    var recentlyClosedByOutsideClick: Bool {
        ProcessInfo.processInfo.systemUptime - lastCloseTimestamp < 0.25
    }

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 300),
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

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = .intrinsicContentSize
        self.hostingView = hosting.view

        let rootContainer = NSView(frame: NSRect(x: 0, y: 0, width: 332, height: 300))
        rootContainer.wantsLayer = true
        rootContainer.layer?.cornerRadius = Self.cornerRadius
        rootContainer.layer?.masksToBounds = true

        let topPinned = TopPinnedContainerView(frame: rootContainer.bounds)
        topPinned.autoresizingMask = [.width, .height]
        hosting.view.frame = NSRect(x: 0, y: 0, width: 332, height: Self.permanentHostingCanvasHeight)
        hosting.view.autoresizingMask = [.width]
        topPinned.addSubview(hosting.view)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSBox(frame: rootContainer.bounds)
            solid.boxType = .custom
            solid.isTransparent = false
            solid.fillColor = .windowBackgroundColor
            solid.borderWidth = 0
            solid.cornerRadius = Self.cornerRadius
            solid.autoresizingMask = [.width, .height]
            rootContainer.addSubview(solid)
            rootContainer.addSubview(topPinned)
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: rootContainer.bounds)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.autoresizingMask = [.width, .height]
            glass.contentView = topPinned
            rootContainer.addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: rootContainer.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            rootContainer.addSubview(effect)
            rootContainer.addSubview(topPinned)
        }

        let wrapperVC = NSViewController()
        wrapperVC.view = rootContainer
        wrapperVC.addChild(hosting)
        self.contentViewController = wrapperVC
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(rectInWindow)
        self.anchorButtonScreenRect = screenRect

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
                    if let self, self.onEscapePressed?() == true {
                        return
                    }
                    self?.dismissPanel()
                }
                return nil
            }
            return event
        }

        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let dy = event.scrollingDeltaY
            if abs(dy) > 0.05 {
                let scaled = event.hasPreciseScrollingDeltas ? dy * 0.0035 : dy * 0.03
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.allowsScrollVolume?() ?? true {
                        self.onScrollDeltaY?(scaled)
                    }
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
