#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift <AppIcon.appiconset>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let menuBarDirectory = outputDirectory.deletingLastPathComponent()
    .appendingPathComponent("MenuBarIcon.imageset", isDirectory: true)
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// The scroll comes from Phosphor Icons 2.1.1 (MIT, see icon-source/LICENSE-phosphor):
// the fill weight for the app icon and the regular weight for the menu bar.
let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("icon-source", isDirectory: true)
guard let filledScroll = NSImage(contentsOf: sourceDirectory.appendingPathComponent("scroll-fill.svg")),
      let outlinedScroll = NSImage(contentsOf: sourceDirectory.appendingPathComponent("scroll-regular.svg")) else {
    fputs("Missing icon sources in \(sourceDirectory.path)\n", stderr)
    exit(1)
}

let yellow = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.13, alpha: 1)
let black = NSColor(calibratedWhite: 0.07, alpha: 1)

/// Draws the glyph mirrored so the sheet faces left, tinted with one color.
func drawGlyph(_ glyph: NSImage, in rect: NSRect, color: NSColor, context: CGContext) {
    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.translateBy(x: rect.midX, y: 0)
    context.scaleBy(x: -1, y: 1)
    context.translateBy(x: -rect.midX, y: 0)
    glyph.draw(in: rect)
    context.setBlendMode(.sourceAtop)
    context.setFillColor(color.cgColor)
    context.fill(rect)
    context.endTransparencyLayer()
    context.restoreGState()
}

func drawIcon(size: Int, menuBar: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "WizardScrollIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvas = CGFloat(size)
    let canvasRect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
    let context = graphicsContext.cgContext

    if menuBar {
        // Black on transparent lets macOS tint the mark for either menu bar
        // appearance.
        drawGlyph(outlinedScroll, in: canvasRect, color: .black, context: context)
    } else {
        let inset = canvas * 0.10
        let side = canvas - inset * 2
        let tileRect = NSRect(x: inset, y: inset, width: side, height: side)
        black.setFill()
        NSBezierPath(roundedRect: tileRect, xRadius: side * 0.225, yRadius: side * 0.225).fill()
        drawGlyph(filledScroll, in: tileRect.insetBy(dx: side * 0.16, dy: side * 0.16), color: yellow, context: context)
    }

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "WizardScrollIcon", code: 2)
    }
    return png
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (name, size) in outputs {
    try drawIcon(size: size).write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}

try FileManager.default.createDirectory(at: menuBarDirectory, withIntermediateDirectories: true)
for (name, size) in [("menu-bar.png", 22), ("menu-bar@2x.png", 44)] {
    try drawIcon(size: size, menuBar: true).write(to: menuBarDirectory.appendingPathComponent(name), options: .atomic)
}
