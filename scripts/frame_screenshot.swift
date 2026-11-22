// Frames a raw README screenshot as a rounded card with a hairline border and transparent corners.
//
// Usage: swift scripts/frame_screenshot.swift <input.png> <output.png> [scale] [keepX keepW stripH]
//
// When `keepX keepW stripH` (points, relative to the captured region) are given, the top `stripH` points — the
// menu bar slice — are scrubbed of everything except the column range `keepX ..< keepX + keepW` (the TrinityBar
// emblem): each row is filled with its own dominant background color, which removes other apps' status items,
// the clock, and glyphs clipped by the crop edge.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: frame_screenshot.swift <input.png> <output.png> [scale] [keepX keepW stripH]\n".utf8))
    exit(64)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let scale = args.count >= 4 ? (Double(args[3]) ?? 2.0) : 2.0
let menuBarMask: (keepX: Double, keepW: Double, stripH: Double)? = args.count >= 7
    ? Double(args[4]).flatMap { x in Double(args[5]).flatMap { w in Double(args[6]).map { h in (x, w, h) } } }
    : nil

let cornerRadiusPt = 18.0
let borderWidthPt = 1.0

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read \(inputURL.path)")
}

let width = raw.width
let height = raw.height
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
let bounds = CGRect(x: 0, y: 0, width: width, height: height)

func makeContext() -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("cannot allocate \(width)x\(height) bitmap")
    }
    return ctx
}

// 1. Menu bar scrub (pixel rows in bitmap memory run top-down).
var image = raw
if let mask = menuBarMask {
    let ctx = makeContext()
    ctx.draw(raw, in: bounds)
    guard let data = ctx.data else { fail("no bitmap data") }
    let px = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let keepMin = max(0, Int((mask.keepX * scale).rounded(.down)))
    let keepMax = min(width, Int(((mask.keepX + mask.keepW) * scale).rounded(.up)))
    let stripRows = min(height, Int((mask.stripH * scale).rounded(.down)))

    let isScrubColumn = { (col: Int) in col < keepMin || col >= keepMax }
    let threshold = 22 // max per-channel deviation from the row background still treated as background
    let dilation = Int((3.0 * scale).rounded()) // grow marks so anti-aliased glyph edges are covered too

    // Pass 1: mark foreground pixels (icons, text) that deviate from their row's dominant background color.
    var marked = [Bool](repeating: false, count: width * stripRows)
    for row in 0..<stripRows {
        let base = row * width * 4
        var counts: [UInt16: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for col in 0..<width where isScrubColumn(col) {
            let i = base + col * 4
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let key = UInt16(r >> 4) << 8 | UInt16(g >> 4) << 4 | UInt16(b >> 4)
            let e = counts[key] ?? (0, 0, 0, 0)
            counts[key] = (e.n + 1, e.r + r, e.g + g, e.b + b)
        }
        guard let bg = counts.values.max(by: { $0.n < $1.n }), bg.n > 0 else { continue }
        let (br, bgc, bb) = (bg.r / bg.n, bg.g / bg.n, bg.b / bg.n)
        for col in 0..<width where isScrubColumn(col) {
            let i = base + col * 4
            let d = max(abs(Int(px[i]) - br), abs(Int(px[i + 1]) - bgc), abs(Int(px[i + 2]) - bb))
            if d > threshold { marked[row * width + col] = true }
        }
    }

    // Pass 2: dilate marks (box), never into the kept emblem columns.
    var grown = marked
    for row in 0..<stripRows {
        for col in 0..<width where marked[row * width + col] {
            for r in max(0, row - dilation)...min(stripRows - 1, row + dilation) {
                for c in max(0, col - dilation)...min(width - 1, col + dilation) where isScrubColumn(c) {
                    grown[r * width + c] = true
                }
            }
        }
    }

    // Pass 3: replace each marked run by linearly interpolating the unmarked pixels on either side of it,
    // preserving the menu bar's own gradient / wallpaper tint instead of painting a flat block.
    for row in 0..<stripRows {
        let base = row * width * 4
        var col = 0
        while col < width {
            guard grown[row * width + col] else { col += 1; continue }
            let start = col
            while col < width && grown[row * width + col] { col += 1 }
            let end = col // exclusive
            let left = start > 0 ? start - 1 : nil
            let right = end < width ? end : nil
            for c in start..<end {
                let t = Double(c - start + 1) / Double(end - start + 1)
                for ch in 0..<4 {
                    let lv = left.map { Double(px[base + $0 * 4 + ch]) }
                    let rv = right.map { Double(px[base + $0 * 4 + ch]) }
                    let v: Double
                    switch (lv, rv) {
                    case let (l?, r?): v = l + (r - l) * t
                    case let (l?, nil): v = l
                    case let (nil, r?): v = r
                    default: v = Double(px[base + c * 4 + ch])
                    }
                    px[base + c * 4 + ch] = UInt8(max(0, min(255, v.rounded())))
                }
            }
        }
    }
    guard let scrubbed = ctx.makeImage() else { fail("cannot build scrubbed image") }
    image = scrubbed
}

// 2. Rounded card + hairline border.
let ctx = makeContext()
let radius = CGFloat(cornerRadiusPt * scale)
let border = CGFloat(borderWidthPt * scale)

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.draw(image, in: bounds)
ctx.restoreGState()

let inset = bounds.insetBy(dx: border / 2, dy: border / 2)
ctx.addPath(CGPath(roundedRect: inset, cornerWidth: radius - border / 2, cornerHeight: radius - border / 2, transform: nil))
ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.22))
ctx.setLineWidth(border)
ctx.strokePath()

guard let framed = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot encode PNG")
}
CGImageDestinationAddImage(dest, framed, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
guard CGImageDestinationFinalize(dest) else {
    fail("cannot write \(outputURL.path)")
}
