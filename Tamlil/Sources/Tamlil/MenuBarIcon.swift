// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Which glyph the menu bar status item shows. Pure mapping from app state so
/// the precedence (recording over processing over idle) is covered by
/// `--self-check` without a status bar.
enum MenuBarIconKind: Equatable {
    case idle
    case recording
    case processing
}

extension MenuBarIconKind {
    init(status: AppState.Status, anyProcessing: Bool) {
        if case .recording = status {
            self = .recording
        } else {
            self = anyProcessing ? .processing : .idle
        }
    }
}

/// Menu bar icon: a waveform turning into the letter ת (tav, for תמליל —
/// "transcript"): audio in, Hebrew text out. Template images, so the system
/// recolors them for menu bar appearance and dark mode.
enum MenuBarIcon {
    static func image(for kind: MenuBarIconKind) -> NSImage {
        switch kind {
        case .idle: return idle
        case .recording: return recording
        case .processing: return processing
        }
    }

    // System symbols are immutable and shared; build each once.
    private static let recording = symbol("record.circle.fill", "Recording")
    private static let processing = symbol("hourglass", "Processing")

    static let idle: NSImage = {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let heights: [CGFloat] = [6, 11, 8]
            for (i, h) in heights.enumerated() {
                let x = CGFloat(i) * 3.0 + 1.0
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: (rect.height - h) / 2, width: 1.8, height: h),
                    xRadius: 0.9, yRadius: 0.9
                ).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let glyph = NSAttributedString(string: "ת", attributes: attrs)
            let glyphSize = glyph.size()
            glyph.draw(at: NSPoint(
                x: rect.width - glyphSize.width - 0.5,
                y: (rect.height - glyphSize.height) / 2
            ))
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage()
        image.isTemplate = true
        return image
    }
}
