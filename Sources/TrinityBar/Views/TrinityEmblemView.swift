import AppKit
import CoreGraphics
import CoreText
import SwiftUI

struct TrinityEmblemState: Equatable, Hashable {
    var hasBattery: Bool
    var batteryPercent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isLowPowerMode: Bool
    var showTopPercentage: Bool
    var connectionKind: ConnectionKind
    var wifiStrengthBars: Int // 0...3
    var bottomMode: BottomIndicatorMode
    var bottomDots: Int // 0...4
    var bottomProgress: Double // 0.0...1.0 (for Volume Arc)
    var isDarkMenuBar: Bool

    init(
        hasBattery: Bool = true,
        batteryPercent: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        isLowPowerMode: Bool,
        showTopPercentage: Bool,
        connectionKind: ConnectionKind,
        wifiStrengthBars: Int,
        bottomMode: BottomIndicatorMode,
        bottomDots: Int,
        bottomProgress: Double,
        isDarkMenuBar: Bool
    ) {
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isLowPowerMode = isLowPowerMode
        self.showTopPercentage = showTopPercentage
        self.connectionKind = connectionKind
        self.wifiStrengthBars = wifiStrengthBars
        self.bottomMode = bottomMode
        self.bottomDots = bottomDots
        self.bottomProgress = bottomProgress
        self.isDarkMenuBar = isDarkMenuBar
    }
}

/// Pure polar-geometry CoreGraphics + CoreText + SF Symbol renderer on a symmetric 100x100 grid,
/// supporting 2x supersampling and split template + chromatic menu bar compositing.
@MainActor
enum TrinityStatusIconRenderer {
    struct MenuBarLayers {
        let templateBase: NSImage
        let chromaticOverlay: CGImage?
    }

    private enum RenderPass {
        case full
        case templateOnly
        case chromaticOnly
    }

    // Symmetric 100x100 polar geometry (top-down Y: 0° = right, 90° = bottom, 180° = left, 270° = top)
    private static let gridSize: CGFloat = 100.0
    private static let ringCenter = CGPoint(x: 50.0, y: 51.5)
    private static let ringRadius: CGFloat = 43.0
    private static let ringStrokeWidth: CGFloat = 8.4
    private static let inactiveAlpha: CGFloat = 0.22

    // Symmetric ±121° battery span around 270° (149° bottom-left -> 391° bottom-right)
    private static let batteryStartDeg: CGFloat = 149.0
    private static let batteryTotalSweepDeg: CGFloat = 242.0
    private static let symbolCrownHalfGapDeg: CGFloat = 24.0
    private static let twoDigitCrownHalfGapDeg: CGFloat = 34.5
    private static let threeDigitCrownHalfGapDeg: CGFloat = 39.5
    private static let crownAccessoryCenter = CGPoint(x: 50.0, y: 12.2)

    // Symmetric ±30° bottom volume indicators around 90° (6 o'clock)
    private static let volumeDotAnglesDeg: [CGFloat] = [120.0, 100.0, 80.0, 60.0]
    private static let volumeDotRadius: CGFloat = 5.1
    private static let volumeArcStartDeg: CGFloat = 121.0
    private static let volumeArcEndDeg: CGFloat = 59.0
    private static let volumeArcStrokeWidth: CGFloat = 7.3

    public static func contentFrame(in bounds: CGRect, contentSize: CGSize) -> CGRect {
        CGRect(
            x: bounds.midX - contentSize.width / 2.0,
            y: bounds.midY - contentSize.height / 2.0,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    public static func menuBarLayers(
        state: TrinityEmblemState,
        size: CGFloat,
        scale: CGFloat,
        appearance: NSAppearance?
    ) -> MenuBarLayers? {
        guard size > 0, scale > 0 else { return nil }
        guard let templateCG = renderCGImage(
            state: state,
            size: size,
            scale: scale,
            appearance: appearance,
            pass: .templateOnly,
            supersample: 2
        ) else {
            return nil
        }

        let baseImage = NSImage(cgImage: templateCG, size: NSSize(width: size, height: size))
        baseImage.isTemplate = true

        let hasChromatic = isRingChromatic(state)
        let overlayCG: CGImage? = hasChromatic
            ? renderCGImage(
                state: state,
                size: size,
                scale: scale,
                appearance: appearance,
                pass: .chromaticOnly,
                supersample: 2
            )
            : nil

        return MenuBarLayers(templateBase: baseImage, chromaticOverlay: overlayCG)
    }

    public static func compositeImage(
        state: TrinityEmblemState,
        size: CGFloat,
        scale: CGFloat = 2.0,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        guard let cg = renderCGImage(
            state: state,
            size: size,
            scale: scale,
            appearance: appearance,
            pass: .full,
            supersample: 2
        ) else {
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        img.isTemplate = false
        return img
    }

    private static func isRingChromatic(_ state: TrinityEmblemState) -> Bool {
        guard state.hasBattery else { return false }
        return state.batteryPercent < 20 || state.isLowPowerMode || state.isCharging || state.isPluggedIn
    }

    private static func resolvedPalette(isDark: Bool, appearance: NSAppearance?) -> (
        foreground: CGColor,
        charging: CGColor,
        lowPower: CGColor,
        critical: CGColor
    ) {
        let targetAppearance = appearance
            ?? NSAppearance(named: isDark ? .darkAqua : .aqua)
            ?? NSAppearance.currentDrawing()

        var charging = CGColor(red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0, alpha: 1.0)
        var lowPower = CGColor(red: 255.0 / 255.0, green: 214.0 / 255.0, blue: 10.0 / 255.0, alpha: 1.0)
        var critical = CGColor(red: 255.0 / 255.0, green: 69.0 / 255.0, blue: 58.0 / 255.0, alpha: 1.0)

        targetAppearance.performAsCurrentDrawingAppearance {
            if let g = NSColor.systemGreen.usingColorSpace(.deviceRGB)?.cgColor { charging = g }
            if let y = NSColor.systemYellow.usingColorSpace(.deviceRGB)?.cgColor { lowPower = y }
            if let r = NSColor.systemRed.usingColorSpace(.deviceRGB)?.cgColor { critical = r }
        }

        let foreground = CGColor(gray: isDark ? 1.0 : 0.0, alpha: 1.0)
        return (foreground, charging, lowPower, critical)
    }

    private static func renderCGImage(
        state: TrinityEmblemState,
        size: CGFloat,
        scale: CGFloat,
        appearance: NSAppearance?,
        pass: RenderPass,
        supersample: Int
    ) -> CGImage? {
        let ss = max(1, min(4, supersample))
        let workingScale = scale * CGFloat(ss)
        let pixelDim = Int((size * workingScale).rounded(.up))
        guard pixelDim > 0,
              let ctx = CGContext(
                  data: nil,
                  width: pixelDim,
                  height: pixelDim,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelDim * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }

        let palette = resolvedPalette(isDark: state.isDarkMenuBar, appearance: appearance)
        let primaryInk = (pass == .templateOnly) ? CGColor(gray: 0.0, alpha: 1.0) : palette.foreground

        ctx.scaleBy(x: workingScale, y: workingScale)
        ctx.saveGState()
        let unitScale = size / gridSize
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: unitScale, y: -unitScale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        drawScene(
            state: state,
            in: ctx,
            pass: pass,
            foreground: primaryInk,
            chargingColor: palette.charging,
            lowPowerColor: palette.lowPower,
            criticalColor: palette.critical
        )
        ctx.restoreGState()

        guard let hiImage = ctx.makeImage() else { return nil }
        guard ss > 1 else { return hiImage }

        let finalDim = Int((size * scale).rounded(.up))
        guard finalDim > 0,
              let finalCtx = CGContext(
                  data: nil,
                  width: finalDim,
                  height: finalDim,
                  bitsPerComponent: 8,
                  bytesPerRow: finalDim * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return hiImage
        }
        finalCtx.interpolationQuality = .high
        finalCtx.draw(hiImage, in: CGRect(x: 0, y: 0, width: finalDim, height: finalDim))
        return finalCtx.makeImage() ?? hiImage
    }

    private static func drawScene(
        state: TrinityEmblemState,
        in ctx: CGContext,
        pass: RenderPass,
        foreground: CGColor,
        chargingColor: CGColor,
        lowPowerColor: CGColor,
        criticalColor: CGColor
    ) {
        let hasTopGap = !state.hasBattery || state.isCharging || state.isPluggedIn || state.showTopPercentage
        let halfGapDeg: CGFloat = {
            if !state.hasBattery || state.isCharging || state.isPluggedIn {
                return symbolCrownHalfGapDeg
            }
            return state.batteryPercent >= 100 ? threeDigitCrownHalfGapDeg : twoDigitCrownHalfGapDeg
        }()
        let pct = state.hasBattery ? Double(min(100, max(0, state.batteryPercent))) / 100.0 : 0.0

        let ringIsColor = isRingChromatic(state)
        let ringFillColor: CGColor = {
            if state.batteryPercent < 20 { return criticalColor }
            if state.isLowPowerMode { return lowPowerColor }
            if state.isCharging || state.isPluggedIn { return chargingColor }
            return foreground
        }()

        // 1a. Battery Ring Track (template layer)
        if pass == .full || pass == .templateOnly {
            ctx.setLineWidth(ringStrokeWidth)
            ctx.setStrokeColor(foreground.copy(alpha: inactiveAlpha) ?? foreground)
            ctx.addPath(batteryArcPath(progress: 1.0, hasTopGap: hasTopGap, halfGapDeg: halfGapDeg))
            ctx.strokePath()
        }

        // 1b. Battery Ring Active Fill
        let drawRingFill = state.hasBattery && (
            (pass == .full)
            || (pass == .templateOnly && !ringIsColor)
            || (pass == .chromaticOnly && ringIsColor)
        )
        if drawRingFill, pct > 0.0 {
            ctx.setLineWidth(ringStrokeWidth)
            ctx.setStrokeColor(ringFillColor)
            ctx.addPath(batteryArcPath(progress: pct, hasTopGap: hasTopGap, halfGapDeg: halfGapDeg))
            ctx.strokePath()
        }

        // 2. Top Crown Accessory (Charging Bolt / AC Plug / Percentage Digits — template layer for vibrancy)
        let drawAccessory = (pass == .full) || (pass == .templateOnly)

        if drawAccessory, hasTopGap {
            ctx.saveGState()
            if pass != .templateOnly {
                ctx.setShadow(
                    offset: CGSize(width: 0, height: 0.6),
                    blur: 0.6,
                    color: CGColor(gray: 0.0, alpha: 0.35)
                )
            }

            if state.hasBattery && state.isCharging {
                drawSymbol(
                    name: "bolt.fill",
                    variableValue: 1.0,
                    pointSize: 21.5,
                    weight: .bold,
                    center: crownAccessoryCenter,
                    foreground: foreground,
                    in: ctx
                )
            } else if !state.hasBattery || state.isPluggedIn {
                let plugName = NSImage(systemSymbolName: "powerplug.portrait.fill", accessibilityDescription: nil) != nil
                    ? "powerplug.portrait.fill"
                    : "powerplug.fill"
                drawSymbol(
                    name: plugName,
                    variableValue: 1.0,
                    pointSize: 20.5,
                    weight: .semibold,
                    center: crownAccessoryCenter,
                    foreground: foreground,
                    in: ctx
                )
            } else if state.showTopPercentage {
                drawCenteredPercentage("\(state.batteryPercent)", color: foreground, center: crownAccessoryCenter, in: ctx)
            }
            ctx.restoreGState()
        }

        // 3. Center Network Glyph (template layer)
        if pass == .full || pass == .templateOnly {
            drawCenterNetwork(state: state, foreground: foreground, in: ctx)
        }

        // 4. Bottom Volume Footer (Dots or Arc on template layer)
        if pass == .full || pass == .templateOnly {
            let inactiveColor = foreground.copy(alpha: inactiveAlpha) ?? foreground
            switch state.bottomMode {
            case .volumeDots:
                for (idx, deg) in volumeDotAnglesDeg.enumerated() {
                    let rad = deg * .pi / 180.0
                    let pt = CGPoint(
                        x: ringCenter.x + cos(rad) * ringRadius,
                        y: ringCenter.y + sin(rad) * ringRadius
                    )
                    ctx.setFillColor(idx < state.bottomDots ? foreground : inactiveColor)
                    ctx.fillEllipse(in: CGRect(
                        x: pt.x - volumeDotRadius,
                        y: pt.y - volumeDotRadius,
                        width: volumeDotRadius * 2.0,
                        height: volumeDotRadius * 2.0
                    ))
                }

            case .volumeArc:
                ctx.setLineWidth(volumeArcStrokeWidth)
                ctx.setLineCap(.round)
                ctx.setStrokeColor(inactiveColor)
                ctx.addPath(singleArcPath(
                    center: ringCenter,
                    radius: ringRadius,
                    startDeg: volumeArcStartDeg,
                    endDeg: volumeArcEndDeg,
                    clockwise: true
                ))
                ctx.strokePath()

                let clamped = min(1.0, max(0.0, state.bottomProgress))
                if clamped > 0.01 {
                    let sweep = volumeArcStartDeg - volumeArcEndDeg
                    let endDeg = volumeArcStartDeg - sweep * CGFloat(clamped)
                    ctx.setStrokeColor(foreground)
                    ctx.addPath(singleArcPath(
                        center: ringCenter,
                        radius: ringRadius,
                        startDeg: volumeArcStartDeg,
                        endDeg: endDeg,
                        clockwise: true
                    ))
                    ctx.strokePath()
                }

            case .none:
                break
            }
        }
    }

    // MARK: - Center Network Rendering

    private static func drawCenterNetwork(state: TrinityEmblemState, foreground: CGColor, in ctx: CGContext) {
        let networkCenter = CGPoint(x: ringCenter.x, y: ringCenter.y + 0.5)
        switch state.connectionKind {
        case .wifi, .other:
            let variableValue: Double = {
                switch state.wifiStrengthBars {
                case 3: return 1.0
                case 2: return 0.66
                case 1: return 0.33
                default: return 0.0
                }
            }()
            drawSymbol(
                name: "wifi",
                variableValue: variableValue,
                pointSize: 50.0,
                weight: .semibold,
                center: networkCenter,
                foreground: foreground,
                in: ctx
            )

        case .ethernet:
            drawSymmetricEthernetBadge(center: CGPoint(x: 50.0, y: 55.0), foreground: foreground, in: ctx)

        case .offline:
            drawSymbol(
                name: "wifi.slash",
                variableValue: 1.0,
                pointSize: 50.0,
                weight: .semibold,
                center: networkCenter,
                foreground: foreground,
                in: ctx
            )
        }
    }

    private static func drawSymmetricEthernetBadge(center: CGPoint, foreground: CGColor, in ctx: CGContext) {
        let outerX: CGFloat = 22.5
        let chevronSpan: CGFloat = 8.5
        let chevronHalfH: CGFloat = 10.5

        ctx.setStrokeColor(foreground)
        ctx.setLineWidth(4.2)

        let left = CGMutablePath()
        left.move(to: CGPoint(x: center.x - outerX + chevronSpan, y: center.y - chevronHalfH))
        left.addLine(to: CGPoint(x: center.x - outerX, y: center.y))
        left.addLine(to: CGPoint(x: center.x - outerX + chevronSpan, y: center.y + chevronHalfH))
        ctx.addPath(left)
        ctx.strokePath()

        let right = CGMutablePath()
        right.move(to: CGPoint(x: center.x + outerX - chevronSpan, y: center.y - chevronHalfH))
        right.addLine(to: CGPoint(x: center.x + outerX, y: center.y))
        right.addLine(to: CGPoint(x: center.x + outerX - chevronSpan, y: center.y + chevronHalfH))
        ctx.addPath(right)
        ctx.strokePath()

        ctx.setFillColor(foreground)
        let dotR: CGFloat = 2.1
        for offset in [-6.5, 0.0, 6.5] as [CGFloat] {
            ctx.fillEllipse(in: CGRect(
                x: center.x + offset - dotR,
                y: center.y - dotR,
                width: dotR * 2.0,
                height: dotR * 2.0
            ))
        }
    }

    // MARK: - Polar Arcs, Optical Symbol & Text Helpers

    private static func singleArcPath(
        center: CGPoint,
        radius: CGFloat,
        startDeg: CGFloat,
        endDeg: CGFloat,
        clockwise: Bool = false
    ) -> CGPath {
        let sub = CGMutablePath()
        sub.addArc(
            center: center,
            radius: radius,
            startAngle: startDeg * .pi / 180.0,
            endAngle: endDeg * .pi / 180.0,
            clockwise: clockwise
        )
        return sub
    }

    private static func batteryArcPath(
        progress: Double,
        hasTopGap: Bool,
        halfGapDeg: CGFloat
    ) -> CGPath {
        let clamped = min(1.0, max(0.0, progress))
        let path = CGMutablePath()
        guard clamped > 0.0 else { return path }

        let targetEndDeg = batteryStartDeg + batteryTotalSweepDeg * CGFloat(clamped)
        guard hasTopGap else {
            path.addPath(singleArcPath(
                center: ringCenter,
                radius: ringRadius,
                startDeg: batteryStartDeg,
                endDeg: targetEndDeg
            ))
            return path
        }

        let gapStartDeg: CGFloat = 270.0 - halfGapDeg
        let gapEndDeg: CGFloat = 270.0 + halfGapDeg

        let leftEndDeg = min(targetEndDeg, gapStartDeg)
        if leftEndDeg > batteryStartDeg {
            path.addPath(singleArcPath(
                center: ringCenter,
                radius: ringRadius,
                startDeg: batteryStartDeg,
                endDeg: leftEndDeg
            ))
        }

        if targetEndDeg > gapEndDeg {
            path.addPath(singleArcPath(
                center: ringCenter,
                radius: ringRadius,
                startDeg: gapEndDeg,
                endDeg: targetEndDeg
            ))
        }
        return path
    }

    private static func drawCenteredPercentage(
        _ text: String,
        color: CGColor,
        center: CGPoint,
        in ctx: CGContext
    ) {
        let fontSize: CGFloat = text.count >= 3 ? 27.5 : 30.0
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let font = baseFont.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? baseFont

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: -fontSize * 0.04,
            .foregroundColor: NSColor(cgColor: color) ?? .white
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let inkBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

        ctx.setFillColor(color)
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        // Optical ink centering on both axes (note flipped textMatrix maps +inkBounds upward in glyph space)
        ctx.textPosition = CGPoint(
            x: center.x - inkBounds.midX,
            y: center.y + inkBounds.midY
        )
        CTLineDraw(line, ctx)
    }

    private static func drawSymbol(
        name: String,
        variableValue: Double,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        center: CGPoint,
        foreground: CGColor,
        in ctx: CGContext
    ) {
        let nsForeground = NSColor(cgColor: foreground) ?? .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(hierarchicalColor: nsForeground))
        guard let image = NSImage(
            systemSymbolName: name,
            variableValue: variableValue,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config) else {
            return
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = gc

        ctx.scaleBy(x: 1.0, y: -1.0)
        let targetRect = CGRect(
            x: center.x - image.size.width / 2.0,
            y: -(center.y + image.size.height / 2.0),
            width: image.size.width,
            height: image.size.height
        )
        image.draw(in: targetRect)
    }
}

/// SwiftUI wrapper used inside PopoverDashboardView so previews share the exact same CoreGraphics renderer.
struct TrinityEmblemView: View {
    let state: TrinityEmblemState
    var size: CGFloat = 24.0

    init(state: TrinityEmblemState, size: CGFloat = 24.0) {
        self.state = state
        self.size = size
    }

    var body: some View {
        Group {
            if let nsImage = TrinityStatusIconRenderer.compositeImage(state: state, size: size, scale: 2.0) {
                Image(nsImage: nsImage)
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
    }
}
