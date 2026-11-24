#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Mapfolio/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// Match SVG 256x256 top-left coordinate system scaled 4x to 1024x1024
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 4.0, y: -4.0)

func gray(_ hex: Int) -> CGColor {
    let v = CGFloat(hex) / 255.0
    return CGColor(colorSpace: colorSpace, components: [v, v, v, 1.0])!
}

let bg = gray(0x09)
let surfaceHi = gray(0x16)
let muted = gray(0x6B)
let secondary = gray(0xA2)
let primary = gray(0xF5)

func makePolygon(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    guard let first = pts.first else { return path }
    path.move(to: CGPoint(x: first.0, y: first.1))
    for p in pts.dropFirst() {
        path.addLine(to: CGPoint(x: p.0, y: p.1))
    }
    path.closeSubpath()
    return path
}

func fillAndStroke(
    _ pts: [(CGFloat, CGFloat)],
    fill: CGColor?,
    stroke: CGColor?,
    lineWidth: CGFloat = 0
) {
    let path = makePolygon(pts)
    if let fill {
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
    if let stroke, lineWidth > 0 {
        ctx.addPath(path)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.miter)
        ctx.setMiterLimit(6.0)
        ctx.strokePath()
    }
}

// Background
ctx.setFillColor(bg)
ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))

// Bottom sheet: modern basemap
fillAndStroke(
    [(128, 122), (202, 162), (128, 202), (54, 162)],
    fill: bg,
    stroke: muted,
    lineWidth: 7.5
)

// Middle sheet: archived folio layer
fillAndStroke(
    [(128, 89), (202, 129), (128, 169), (54, 129)],
    fill: bg,
    stroke: secondary,
    lineWidth: 7.5
)

// Top sheet fill
let topSheet: [(CGFloat, CGFloat)] = [(128, 54), (202, 94), (128, 134), (54, 94)]
fillAndStroke(topSheet, fill: surfaceHi, stroke: nil)

// 4-quadrant fold creases on top sheet
ctx.setStrokeColor(secondary)
ctx.setLineWidth(5.5)
ctx.setLineCap(.butt)
ctx.move(to: CGPoint(x: 91, y: 74))
ctx.addLine(to: CGPoint(x: 165, y: 114))
ctx.move(to: CGPoint(x: 165, y: 74))
ctx.addLine(to: CGPoint(x: 91, y: 114))
ctx.strokePath()

// Top sheet crisp primary border (caps crease endpoints cleanly)
fillAndStroke(topSheet, fill: nil, stroke: primary, lineWidth: 8.0)

// Central isometric calibration diamond
fillAndStroke([(128, 81), (149, 94), (128, 107), (107, 94)], fill: primary, stroke: nil)
fillAndStroke([(128, 89), (136, 94), (128, 99), (120, 94)], fill: bg, stroke: nil)

guard let image = ctx.makeImage() else {
    fputs("Failed to make CGImage\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fputs("Failed to create image destination at \(outputPath)\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
if !CGImageDestinationFinalize(destination) {
    fputs("Failed to write PNG to \(outputPath)\n", stderr)
    exit(1)
}

print("Wrote \(size)x\(size) icon to \(outputPath)")
