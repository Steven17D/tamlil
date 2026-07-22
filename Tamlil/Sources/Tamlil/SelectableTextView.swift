// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// What a mouse-up in a transcript line resolved to: a click on a flagged
/// term, or a drag selection of arbitrary text. `rect` is the term/selection
/// bounds in the view's own (top-left origin) coordinate space, used to
/// anchor the correction popup under the text like macOS spellcheck.
struct TextHit: Identifiable {
    enum Kind {
        case flag(id: String)
        case selection
    }

    let kind: Kind
    let text: String
    let rect: CGRect

    var id: String {
        switch kind {
        case .flag(let id): return "flag-\(id)"
        case .selection: return "sel-\(text)-\(Int(rect.minX))-\(Int(rect.minY))"
        }
    }
}

/// Non-editable, selectable text surface for one transcript line. Flagged
/// terms get spell-check style underlines (red squiggle = likely wrong, gray
/// dots = minor doubt); lines that read right-to-left get an RTL base
/// direction and right alignment, so Hebrew renders correctly without bidi
/// control characters. Flag clicks and drag selections surface via `onHit`.
struct SelectableTextView: NSViewRepresentable {
    let text: String
    let flags: [(flag: Clarification, range: Range<String.Index>)]
    var onHit: (TextHit) -> Void

    func makeNSView(context: Context) -> HitTextView {
        // TextKit 1 explicitly: the squiggle, hit-testing, and sizing all go
        // through NSLayoutManager, so don't rely on the implicit downgrade
        // that the first `.layoutManager` access would trigger.
        let view = HitTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        apply(to: view)
        return view
    }

    func updateNSView(_ view: HitTextView, context: Context) {
        apply(to: view)
    }

    /// SwiftUI proposes a width; answer with the height the wrapped text needs.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HitTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        guard width.isFinite else {
            return CGSize(width: ceil(used.width), height: ceil(used.height))
        }
        return CGSize(width: width, height: ceil(used.height))
    }

    private func apply(to view: HitTextView) {
        view.onHit = onHit
        let specs = flags.map {
            HitTextView.FlagSpec(id: $0.flag.id,
                                 range: NSRange($0.range, in: text),
                                 isWrong: $0.flag.isWrong)
        }
        // Rewriting storage resets any live selection, and SwiftUI calls
        // updateNSView on unrelated parent state changes — skip unless the
        // content actually changed.
        guard view.appliedText != text || view.flagSpecs != specs else { return }
        view.appliedText = text
        view.flagSpecs = specs
        view.textStorage?.setAttributedString(attributed())
        // The red squiggle only draws as a layout-manager temporary attribute;
        // putting .spellingState in the storage renders nothing.
        if let layout = view.layoutManager {
            // Don't rely on setAttributedString clearing old temporaries.
            layout.removeTemporaryAttribute(
                .spellingState,
                forCharacterRange: NSRange(location: 0, length: (text as NSString).length)
            )
            for spec in specs where spec.isWrong {
                layout.addTemporaryAttribute(
                    .spellingState,
                    value: NSAttributedString.SpellingState.spelling.rawValue,
                    forCharacterRange: spec.range
                )
            }
        }
    }

    private func attributed() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        if text.isRTL {
            paragraph.baseWritingDirection = .rightToLeft
            paragraph.alignment = .right
        }
        let a = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .callout),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        for (flag, range) in flags {
            let r = NSRange(range, in: text)
            if flag.isWrong {
                a.addAttribute(.foregroundColor, value: NSColor.systemRed, range: r)
            } else {
                a.addAttributes([
                    .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                    .underlineColor: NSColor.secondaryLabelColor,
                ], range: r)
            }
        }
        return a
    }
}

/// NSTextView that turns mouse-ups into flag/selection hits. `mouseDown`
/// runs AppKit's full click-or-drag tracking loop, so when super returns the
/// selection is final: a non-empty selection is a drag (or double-click), an
/// empty one is a click that may have landed on a flagged term.
final class HitTextView: NSTextView {
    struct FlagSpec: Equatable {
        let id: String
        let range: NSRange
        let isWrong: Bool
    }

    var flagSpecs: [FlagSpec] = []
    var appliedText: String?
    var onHit: ((TextHit) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let sel = selectedRange()
        if sel.length > 0 {
            reportSelection(sel)
            return
        }
        reportFlagClick(at: convert(event.locationInWindow, from: nil))
    }

    private func reportSelection(_ sel: NSRange) {
        let raw = (string as NSString).substring(with: sel)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A selection of pure whitespace/punctuation isn't correctable.
        guard text.contains(where: { !$0.isPunctuation && !$0.isWhitespace }) else { return }
        // A double-click that selects exactly a flagged term keeps the flag's
        // identity, so the popup retains its guess and audio slice.
        if let spec = flagSpecs.first(where: { $0.range == sel }) {
            onHit?(TextHit(kind: .flag(id: spec.id), text: text, rect: rect(for: sel)))
            return
        }
        onHit?(TextHit(kind: .selection, text: text, rect: rect(for: sel)))
    }

    private func reportFlagClick(at point: NSPoint) {
        guard let layout = layoutManager, let container = textContainer else { return }
        var p = point
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        let index = layout.characterIndex(
            for: p, in: container, fractionOfDistanceBetweenInsertionPoints: nil
        )
        for spec in flagSpecs where NSLocationInRange(index, spec.range) {
            // characterIndex returns the NEAREST character, so a click in the
            // row's blank space would otherwise hit the closest flag.
            guard rect(for: spec.range).insetBy(dx: -2, dy: -2).contains(point)
            else { continue }
            let term = (string as NSString).substring(with: spec.range)
            onHit?(TextHit(kind: .flag(id: spec.id), text: term, rect: rect(for: spec.range)))
            return
        }
    }

    private func rect(for range: NSRange) -> CGRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }
}
