import AppKit
import XCTest
@testable import TrinityBar

@MainActor
final class StatusFloatingPanelTests: XCTestCase {
    // MARK: - scaledVolumeDelta

    func testSmallDeltasAreIgnored() {
        for dy: CGFloat in [0, 0.05, -0.05, 0.01] {
            XCTAssertNil(StatusFloatingPanel.scaledVolumeDelta(dy: dy, isPrecise: true), "\(dy)")
            XCTAssertNil(StatusFloatingPanel.scaledVolumeDelta(dy: dy, isPrecise: false), "\(dy)")
        }
    }

    func testPreciseScrollScaling() throws {
        let value = try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: 100, isPrecise: true))
        XCTAssertEqual(value, 0.03, accuracy: 1e-9)
        let negative = try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: -100, isPrecise: true))
        XCTAssertEqual(negative, -0.03, accuracy: 1e-9)
    }

    func testLineScrollScaling() throws {
        let value = try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: 3, isPrecise: false))
        XCTAssertEqual(value, 0.03, accuracy: 1e-9)
        let negative = try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: -1, isPrecise: false))
        XCTAssertEqual(negative, -0.01, accuracy: 1e-9)
    }

    func testDeltaIsClampedToEightPercent() throws {
        XCTAssertEqual(try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: 1000, isPrecise: true)), 0.08, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: -1000, isPrecise: true)), -0.08, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: 50, isPrecise: false)), 0.08, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(StatusFloatingPanel.scaledVolumeDelta(dy: -50, isPrecise: false)), -0.08, accuracy: 1e-9)
    }

    // MARK: - panelFrame

    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let panelSize = NSSize(width: 332, height: 400)

    private func frame(anchor: NSRect, visible: NSRect? = nil, size: NSSize? = nil, inset: CGFloat = StatusFloatingPanel.screenMargin) -> NSRect {
        StatusFloatingPanel.panelFrame(
            panelSize: size ?? panelSize,
            anchorScreenRect: anchor,
            visibleFrame: visible ?? self.visible,
            horizontalInset: inset
        )
    }

    func testCentersUnderAnchorBelowMenuBarGap() {
        let anchor = NSRect(x: 700, y: 875, width: 40, height: 24)
        let result = frame(anchor: anchor)
        XCTAssertEqual(result.midX, anchor.midX)
        XCTAssertEqual(result.maxY, anchor.minY - StatusFloatingPanel.menuBarGap)
        XCTAssertEqual(result.size, panelSize)
    }

    func testClampedToLeftEdgeWithInset() {
        let anchor = NSRect(x: 10, y: 875, width: 30, height: 24)
        XCTAssertEqual(frame(anchor: anchor).minX, visible.minX + StatusFloatingPanel.screenMargin)
        XCTAssertEqual(frame(anchor: anchor, inset: 40).minX, visible.minX + 40)
    }

    func testClampedToRightEdgeWithInset() {
        let anchor = NSRect(x: 1410, y: 875, width: 30, height: 24)
        XCTAssertEqual(frame(anchor: anchor).maxX, visible.maxX - StatusFloatingPanel.screenMargin)
        XCTAssertEqual(frame(anchor: anchor, inset: 40).maxX, visible.maxX - 40)
    }

    func testRespectsNonZeroVisibleOrigin() {
        // Secondary display to the left of the main screen.
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        let anchor = NSRect(x: -1910, y: 1055, width: 30, height: 24)
        XCTAssertEqual(frame(anchor: anchor, visible: secondary).minX, secondary.minX + StatusFloatingPanel.screenMargin)
    }

    func testBottomNeverBelowVisibleMinPlusMargin() {
        let shortVisible = NSRect(x: 0, y: 100, width: 1440, height: 300)
        let anchor = NSRect(x: 700, y: 400, width: 40, height: 24)
        let result = frame(anchor: anchor, visible: shortVisible)
        XCTAssertEqual(result.minY, shortVisible.minY + StatusFloatingPanel.screenMargin)
        XCTAssertEqual(result.height, panelSize.height)
    }

    func testOriginIsRounded() {
        let anchor = NSRect(x: 700.3, y: 875.4, width: 41.1, height: 24)
        let result = frame(anchor: anchor)
        XCTAssertEqual(result.minX, result.minX.rounded())
        XCTAssertEqual(result.minY, result.minY.rounded())
        XCTAssertEqual(result.minX, (anchor.midX - panelSize.width / 2).rounded())
        XCTAssertEqual(result.minY, (anchor.minY - StatusFloatingPanel.menuBarGap - panelSize.height).rounded())
    }
}
