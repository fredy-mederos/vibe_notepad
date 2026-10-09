#!/usr/bin/env swift
// Renders the Vibe Notepad app icon into the asset catalog.
// Usage: swift scripts/generate_icon.swift <path-to-AppIcon.appiconset>
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "VibeNotepad/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon on a 1024×1024 canvas (Big Sur style squircle with margins).
func drawIcon(in ctx: CGContext) {
    let canvas: CGFloat = 1024
    let inset: CGFloat = 100
    let tile = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius: CGFloat = 186
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1A1033))
    ctx.fillPath()
    ctx.restoreGState()

    // Vibrant diagonal gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x2B1B6E), color(0x6B3CF0), color(0xD14BD8), color(0xFF8A5B)] as CFArray, locations: [0, 0.42, 0.78, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // Soft glow blobs.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 770), startRadius: 0, endCenter: CGPoint(x: 330, y: 770), endRadius: 420, options: [])
    let glow2 = CGGradient(colorsSpace: space, colors: [color(0x3EC6FF, 0.45), color(0x3EC6FF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow2, startCenter: CGPoint(x: 820, y: 230), startRadius: 0, endCenter: CGPoint(x: 820, y: 230), endRadius: 380, options: [])

    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.maxY - 300), options: [])
    ctx.restoreGState()

    // The page, slightly rotated.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: -0.07)
    let page = CGRect(x: -235, y: -285, width: 470, height: 570)
    let pagePath = CGPath(roundedRect: page, cornerWidth: 58, cornerHeight: 58, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: color(0x12062E, 0.55))
    ctx.addPath(pagePath)
    ctx.setFillColor(color(0x15131F, 0.96))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Glassy rim.
    ctx.addPath(pagePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(5)
    ctx.strokePath()

    // Window dots.
    let dots: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
    for (i, hex) in dots.enumerated() {
        ctx.setFillColor(color(hex))
        ctx.fillEllipse(in: CGRect(x: page.minX + 46 + CGFloat(i) * 42, y: page.maxY - 72, width: 24, height: 24))
    }

    // Syntax-colored code lines.
    let lines: [(indent: CGFloat, segments: [(CGFloat, UInt32)])] = [
        (0, [(90, 0xC49BFF), (150, 0x82AAFF)]),
        (40, [(70, 0xFF8CA8), (40, 0x89DDFF), (130, 0xA8E07A)]),
        (40, [(110, 0xFF8CA8), (40, 0x89DDFF), (80, 0xFFB86B)]),
        (40, [(60, 0xC49BFF), (170, 0x6CD4FF)]),
        (0, [(36, 0x9AA3BF)]),
        (0, [(200, 0x6B7089)]),
    ]
    var y = page.maxY - 150
    for line in lines {
        var x = page.minX + 50 + line.indent
        for (width, hex) in line.segments {
            let pill = CGRect(x: x, y: y, width: width, height: 30)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 15, cornerHeight: 15, transform: nil))
            ctx.setFillColor(color(hex))
            ctx.fillPath()
            x += width + 16
        }
        y -= 62
    }

    // Blinking caret.
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(CGPath(roundedRect: CGRect(x: page.minX + 50 + 36 + 16, y: page.maxY - 150 - 62 * 4 - 8, width: 12, height: 46), cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // Sparkle.
    func sparkle(center: CGPoint, size: CGFloat, alpha: CGFloat) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y + size))
        path.addQuadCurve(to: CGPoint(x: center.x + size, y: center.y), control: CGPoint(x: center.x + size * 0.18, y: center.y + size * 0.18))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - size), control: CGPoint(x: center.x + size * 0.18, y: center.y - size * 0.18))
        path.addQuadCurve(to: CGPoint(x: center.x - size, y: center.y), control: CGPoint(x: center.x - size * 0.18, y: center.y - size * 0.18))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + size), control: CGPoint(x: center.x - size * 0.18, y: center.y + size * 0.18))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 24, color: color(0xFFFFFF, 0.8))
        ctx.addPath(path)
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }
    sparkle(center: CGPoint(x: 762, y: 780), size: 74, alpha: 1)
    sparkle(center: CGPoint(x: 846, y: 676), size: 32, alpha: 0.9)
}

func render(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int, String)] = [
    ("16x16", 16, "1x"), ("16x16", 32, "2x"), ("32x32", 32, "1x"), ("32x32", 64, "2x"),
    ("128x128", 128, "1x"), ("128x128", 256, "2x"), ("256x256", 256, "1x"), ("256x256", 512, "2x"),
    ("512x512", 512, "1x"), ("512x512", 1024, "2x"),
]
var images: [[String: String]] = []
for (size, pixels, scale) in variants {
    let name = "icon_\(size)@\(scale).png"
    try render(size: pixels).write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": size, "scale": scale, "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outputDirectory.path)")
