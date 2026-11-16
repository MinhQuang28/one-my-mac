#!/usr/bin/env swift
// Generates Resources/AppIcon.icns (run from the repo root).
//
// Drawn in code rather than committed as a binary so the icon can be tweaked in a diff, and so the
// repository carries no opaque asset whose provenance has to be explained in the source audit.
//
//   swift tools/make-icon.swift
import AppKit

/// OneMac logo: a white gauge glyph on a blue → violet squircle (same SF Symbol as the menu bar).
let symbolName = "gauge.with.dots.needle.67percent"

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    let scale = size / 1024

    let inset = 100 * scale
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.48, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.95, alpha: 1),
    ])?.draw(in: path, angle: -60)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])?
        .draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: (size - g.width) / 2, y: (size - g.height) / 2, width: g.width, height: g.height))
    }
    return image
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes `iconutil` expects, each as both 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scaleFactor in [1, 2] {
        let pixels = CGFloat(base * scaleFactor)
        let image = drawIcon(size: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { continue }
        let name = scaleFactor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
print(convert.terminationStatus == 0
    ? "wrote Resources/AppIcon.icns"
    : "iconutil failed with status \(convert.terminationStatus)")
