// SPDX-License-Identifier: GPL-3.0-or-later
// Draws Resources/AppIcon.icns: a white glyph on a full-bleed gradient. macOS
// 26 and later cut app icons to their own shape, so the art runs edge to edge
// and the corners are left to the system.
//
//     swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

// The glyph: an SF Symbol name, or a PNG in Resources whose alpha is the shape.
let glyph = "gauge.with.dots.needle.67percent"
let top = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.62, alpha: 1)
let bottom = NSColor(srgbRed: 0.05, green: 0.40, blue: 0.45, alpha: 1)
let glyphScale: CGFloat = 0.58

func glyphImage() -> NSImage {
    let png = root.appendingPathComponent("Resources/\(glyph)")
    if glyph.hasSuffix(".png"), let image = NSImage(contentsOf: png) { return image }
    let configuration = NSImage.SymbolConfiguration(pointSize: 512, weight: .medium)
    return NSImage(systemSymbolName: glyph, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSGradient(starting: top, ending: bottom)!.draw(in: canvas, angle: -90)

    let image = glyphImage()
    let side = CGFloat(size) * glyphScale
    let aspect = image.size.width / image.size.height
    let box = aspect >= 1 ? NSSize(width: side, height: side / aspect) : NSSize(width: side * aspect, height: side)
    let rect = NSRect(x: (CGFloat(size) - box.width) / 2, y: (CGFloat(size) - box.height) / 2,
                      width: box.width, height: box.height)
    // Tint the glyph white by using it as a mask.
    let tinted = NSImage(size: box, flipped: false) { bounds in
        image.draw(in: bounds)
        NSColor.white.set()
        bounds.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
print("wrote \(icns.path)")
