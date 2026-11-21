#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

/// Generates an ultra-compact (~50 KB) single-chunk `1024x1024` (`ic10` lossless PNG) `AppIcon.icns`
/// with a clean flat-minimalist macOS squircle and TrinityBar's signature 3-in-1 vector emblem.

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = projectRoot.appendingPathComponent("Sources/TrinityBar/Resources", isDirectory: true)
try fileManager.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

func singleArcPath(
    center: CGPoint,
    radius: CGFloat,
    startDeg: CGFloat,
    endDeg: CGFloat,
    clockwise: Bool = false
) -> CGPath {
    let p = CGMutablePath()
    p.addArc(
        center: center,
        radius: radius,
        startAngle: startDeg * .pi / 180.0,
        endAngle: endDeg * .pi / 180.0,
        clockwise: clockwise
    )
    return p
}

@MainActor
func renderMinimalistIconPNG(pixelSize: Int = 1024) throws -> Data {
    let dim = CGFloat(pixelSize)
    let scale = dim / 1024.0

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: pixelSize * 4,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Top-down 1024x1024 logical coordinate space
    ctx.translateBy(x: 0, y: dim)
    ctx.scaleBy(x: scale, y: -scale)

    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.4
    let squircleBezier = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

    let squirclePath: CGPath = {
        let p = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<squircleBezier.elementCount {
            let type = squircleBezier.element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                p.move(to: points[0])
            case .lineTo:
                p.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                p.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                p.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                p.closeSubpath()
            @unknown default:
                break
            }
        }
        return p
    }()

    // 1. Clean solid obsidian-slate squircle base (compresses with >95% PNG efficiency)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    ctx.setFillColor(CGColor(red: 0.085, green: 0.105, blue: 0.155, alpha: 1.0))
    ctx.fill(tileRect)

    // 2. Crisp Vector TrinityBar 3-in-1 Emblem in 120x120 canonical space
    ctx.saveGState()
    let emblemBoxSize: CGFloat = 568.0
    let emblemOriginX = (1024.0 - emblemBoxSize) / 2.0
    let emblemOriginY = (1024.0 - emblemBoxSize) / 2.0 + 4.0
    ctx.translateBy(x: emblemOriginX, y: emblemOriginY)
    let unit = emblemBoxSize / 120.0
    ctx.scaleBy(x: unit, y: unit)

    let center = CGPoint(x: 60.0, y: 61.5)
    let ringRadius: CGFloat = 50.5
    let ringStroke: CGFloat = 10.0

    // Left & Right Battery Brackets (independent subpaths — open crown & open footer)
    ctx.setStrokeColor(CGColor(red: 0.20, green: 0.87, blue: 0.50, alpha: 1.0))
    ctx.setLineWidth(ringStroke)
    ctx.setLineCap(.round)
    ctx.addPath(singleArcPath(center: center, radius: ringRadius, startDeg: 146, endDeg: 235, clockwise: false))
    ctx.strokePath()
    ctx.addPath(singleArcPath(center: center, radius: ringRadius, startDeg: 305, endDeg: 394, clockwise: false))
    ctx.strokePath()

    // Top Crown Lightning Bolt
    let boltPath = CGMutablePath()
    boltPath.move(to: CGPoint(x: 63.0, y: 2.5))
    boltPath.addLine(to: CGPoint(x: 50.8, y: 16.6))
    boltPath.addLine(to: CGPoint(x: 58.9, y: 16.6))
    boltPath.addLine(to: CGPoint(x: 56.5, y: 28.5))
    boltPath.addLine(to: CGPoint(x: 69.0, y: 13.9))
    boltPath.addLine(to: CGPoint(x: 60.8, y: 13.9))
    boltPath.closeSubpath()

    ctx.addPath(boltPath)
    ctx.setFillColor(CGColor(red: 0.98, green: 1.0, blue: 0.99, alpha: 1.0))
    ctx.fillPath()

    // Center 3-Bar Wi-Fi Core
    let wifiApex = CGPoint(x: 60.0, y: 81.5)
    let wifiStroke: CGFloat = 5.8
    let wifiRadii: [(r: CGFloat, halfAngle: CGFloat)] = [
        (36.0, 41.5),
        (25.0, 40.5),
        (14.0, 39.0)
    ]

    ctx.setStrokeColor(CGColor(red: 0.97, green: 0.99, blue: 1.0, alpha: 0.98))
    ctx.setLineWidth(wifiStroke)
    ctx.setLineCap(.round)

    for bar in wifiRadii {
        let arc = singleArcPath(
            center: wifiApex,
            radius: bar.r,
            startDeg: 270.0 - bar.halfAngle,
            endDeg: 270.0 + bar.halfAngle,
            clockwise: false
        )
        ctx.addPath(arc)
        ctx.strokePath()
    }

    let dotR: CGFloat = 4.4
    ctx.setFillColor(CGColor(red: 0.97, green: 0.99, blue: 1.0, alpha: 0.98))
    ctx.fillEllipse(in: CGRect(x: wifiApex.x - dotR, y: wifiApex.y - dotR - 1.5, width: dotR * 2, height: dotR * 2))

    // Bottom 4 Curved Volume Dots (3 active sky-blue dots + 1 subtle track dot)
    let dotAnglesDeg: [CGFloat] = [118.0, 99.5, 80.5, 62.0]
    let dotOrbitRadius: CGFloat = 50.5
    let volDotRadius: CGFloat = 5.4

    for (idx, deg) in dotAnglesDeg.enumerated() {
        let rad = deg * .pi / 180.0
        let pt = CGPoint(
            x: center.x + cos(rad) * dotOrbitRadius,
            y: center.y + sin(rad) * dotOrbitRadius
        )
        let dotRect = CGRect(
            x: pt.x - volDotRadius,
            y: pt.y - volDotRadius,
            width: volDotRadius * 2,
            height: volDotRadius * 2
        )
        if idx < 3 {
            ctx.setFillColor(CGColor(red: 0.54, green: 0.82, blue: 1.0, alpha: 1.0))
        } else {
            ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.24))
        }
        ctx.fillEllipse(in: dotRect)
    }

    ctx.restoreGState() // end 120x120 emblem space

    // 3. Crisp inner rim border around squircle
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))
    ctx.setLineWidth(4.0)
    ctx.strokePath()

    ctx.restoreGState() // end squircle clip
    NSGraphicsContext.restoreGraphicsState()

    rep.size = NSSize(width: 512, height: 512) // 144 DPI metadata (512pt @2x = 1024px)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 1)
    }
    return png
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

let png1024 = try MainActor.assumeIsolated { try renderMinimalistIconPNG(pixelSize: 1024) }

// Pack single `ic10` (1024x1024 PNG) chunk into valid macOS .icns container
var icnsData = Data()
icnsData.append(contentsOf: "icns".utf8)
appendUInt32BE(UInt32(16 + png1024.count), to: &icnsData)
icnsData.append(contentsOf: "ic10".utf8)
appendUInt32BE(UInt32(8 + png1024.count), to: &icnsData)
icnsData.append(png1024)

let outputICNS = resourcesDir.appendingPathComponent("AppIcon.icns")
try icnsData.write(to: outputICNS, options: .atomic)
print("Generated ultra-compact AppIcon.icns: \(icnsData.count / 1024) KB (\(icnsData.count) bytes)")
