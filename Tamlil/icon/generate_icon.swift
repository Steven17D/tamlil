// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

// Generates the Tamlil app icon: waveform flowing into the letter ת
// (tav, for "tamlil" — transcript) on an ice-gradient squircle.
// Usage: swift generate_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: ~824pt content on a 1024 canvas, continuous-corner rect.
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)

    // Drop shadow behind the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()

    // Ice gradient: glacial light blue down to deep arctic navy.
    squircle.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.66, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.33, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -68)

    // Subtle highlight sweep across the top.
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    sheen.draw(in: CGRect(x: 100, y: 564, width: 824, height: 360), angle: -90)

    // Waveform bars (left) feeding into the tav (right) — the same mark as
    // the menu bar icon, scaled up.
    NSColor.white.setFill()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)

    let midY: CGFloat = 512
    let barWidth: CGFloat = 64
    let heights: [CGFloat] = [180, 330, 240]
    for (i, h) in heights.enumerated() {
        let x = 200 + CGFloat(i) * 104
        NSBezierPath(
            roundedRect: CGRect(x: x, y: midY - h / 2, width: barWidth, height: h),
            xRadius: barWidth / 2, yRadius: barWidth / 2
        ).fill()
    }

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 430, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let glyph = NSAttributedString(string: "ת", attributes: attrs)
    let glyphSize = glyph.size()
    glyph.draw(at: NSPoint(x: 524 + (300 - glyphSize.width) / 2,
                           y: midY - glyphSize.height / 2))
    ctx.restoreGState()

    return true
}

let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
