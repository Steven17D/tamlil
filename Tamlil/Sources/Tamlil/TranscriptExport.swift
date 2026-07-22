// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Plain-text rendering of a resolved transcript: one `Speaker: text` line per
/// entry. The caller resolves speaker display names (the same way the Markdown
/// export does) and passes the finished lines, keeping this pure and testable.
func transcriptPlainText(lines: [(speaker: String, text: String)]) -> String {
    lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
}

/// A single content-height PDF page of the given transcript text. Sized to the
/// laid-out text so nothing is clipped; no pagination (one tall page).
@MainActor
func transcriptPDFData(_ text: String) -> Data {
    let width: CGFloat = 540
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    textView.isEditable = false
    textView.font = NSFont.systemFont(ofSize: 11)
    textView.textContainerInset = NSSize(width: 8, height: 12)
    textView.string = text
    if let lm = textView.layoutManager, let tc = textView.textContainer {
        lm.ensureLayout(for: tc)
        let height = ceil(lm.usedRect(for: tc).height) + 24
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
    return textView.dataWithPDF(inside: textView.bounds)
}

/// Present a save panel and write `data` to the chosen location. Best-effort.
@MainActor
func saveExport(_ data: Data, suggestedName: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? data.write(to: url)
}
