import AppKit
import Foundation
import ImageIO

/// Deterministic, privacy-safe presentation used by `scripts/capture_screenshots.sh` to produce README assets.
///
/// Enabled only when the `TRINITYBAR_SCREENSHOT` environment variable names a scene, so normal launches are
/// unaffected. While active, personally identifying network details (SSID, BSSID, IP addresses, router, DNS)
/// are replaced with neutral demo values, the panel opens itself on the requested scene, and the panel/menu bar
/// geometry is written as JSON to `TRINITYBAR_SCREENSHOT_INFO` so the script can crop the capture.
enum ScreenshotMode {
    enum Scene: String, Sendable {
        /// Collapsed summary dashboard.
        case summary
        /// Summary dashboard with the Settings drawer expanded.
        case settings
    }

    static let scene: Scene? = ProcessInfo.processInfo.environment["TRINITYBAR_SCREENSHOT"].flatMap(Scene.init(rawValue:))
    static let infoPath: String? = ProcessInfo.processInfo.environment["TRINITYBAR_SCREENSHOT_INFO"]

    static var isActive: Bool { scene != nil }

    /// Delay after launch before the panel opens, so the first battery / Wi-Fi / audio readings have landed.
    static let presentDelay: Duration = .seconds(2)
    /// Delay after the panel opens before geometry is reported, so latency and throughput cards show live values.
    static let settleDelay: Duration = .seconds(5)

    /// Minimum gap between the panel and the screen edges; must exceed the capture script's `SIDE_MARGIN` (25pt)
    /// so the region never runs off-screen when the emblem sits near the right edge.
    static let panelEdgeInset: CGFloat = 26

    /// Full-screen, click-through window showing the desktop wallpaper just below the menu bar level, so the glass
    /// panel blurs over a clean desktop instead of whatever app windows happen to be open (falls back to a neutral
    /// dark fill if the wallpaper can't be loaded, e.g. for dynamic / aerial wallpapers).
    @MainActor
    static func makeWallpaperBackdrop(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let image = wallpaperImage(at: url, dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) {
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
        }
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        return window
    }

    /// Loads the wallpaper frame macOS is actually showing. Light/dark dynamic HEIC wallpapers store both
    /// variants plus an `apple_desktop:apr` XMP tag (base64 plist `{l: lightIndex, d: darkIndex}`); taking the
    /// first frame would show the light variant in Dark Mode and mismatch the menu bar's own appearance.
    private static func wallpaperImage(at url: URL, dark: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var index = 0
        if count > 1 {
            index = dark ? 1 : 0
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
               let encoded = CGImageMetadataCopyStringValueWithPath(meta, nil, "apple_desktop:apr" as CFString) as String?,
               let data = Data(base64Encoded: encoded),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let mapped = plist[dark ? "d" : "l"] as? Int,
               (0..<count).contains(mapped) {
                index = mapped
            }
        }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    enum Demo {
        static let ssid = "Home Wi-Fi"
        static let bssid = "a4:2b:b0:12:34:56"
        static let ipv4 = "192.168.1.20"
        static let ipv6 = "fd00::20"
        static let router = "192.168.1.1"
        static let dns = "1.1.1.1, 8.8.8.8"
    }

    /// Writes the panel frame, status button frame and display scale in top-left-origin global points
    /// (the coordinate space `screencapture -R` expects).
    @MainActor
    static func writeGeometry(panelFrame: NSRect, buttonFrame: NSRect) {
        guard let infoPath else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonFrame) }) ?? NSScreen.main
        func topLeft(_ r: NSRect) -> [String: Double] {
            ["x": r.minX, "y": primaryHeight - r.maxY, "w": r.width, "h": r.height]
        }
        let payload: [String: Any] = [
            "scene": scene?.rawValue ?? "",
            "scale": screen?.backingScaleFactor ?? 2,
            "screenTop": primaryHeight - (screen?.frame.maxY ?? primaryHeight),
            "panel": topLeft(panelFrame),
            "button": topLeft(buttonFrame)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        // Atomic write (temp file + rename) so the capture script never reads a half-written file.
        try? data.write(to: URL(fileURLWithPath: infoPath), options: .atomic)
    }
}
