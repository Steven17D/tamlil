// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Spellcheck-style correction bar shown in a popover under a flagged word
/// or a text selection: tappable suggestions, a free-form fix field, optional
/// playback of the flagged audio slice, and a close button. Accepting hands
/// the correction back; the caller owns dismissal and persistence.
struct CorrectionPopover: View {
    let heard: String
    let suggestions: [String]
    let audio: AudioSlice?
    var stopOtherPlayback: () -> Void = {}
    var onAccept: (String) -> Void
    var onClose: () -> Void

    @State private var custom = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(suggestions, id: \.self) { s in
                SuggestionChip(label: s) { onAccept(s) }
            }
            TextField("fix", text: $custom)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 120)
                .multilineTextAlignment(heard.isRTL ? .trailing : .leading)
                .focused($fieldFocused)
                .onSubmit(acceptCustom)
            if let audio {
                AudioSliceButton(slice: audio, help: "Hear what was said",
                                 stopOtherPlayback: stopOtherPlayback)
            }
            Divider().frame(height: 14)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { fieldFocused = suggestions.isEmpty }
    }

    private func acceptCustom() {
        let c = custom.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        onAccept(c)
    }
}

/// Tappable suggestion shared by the correction and speaker-rename popovers;
/// Hebrew labels get RTL embedding so they render correctly inline.
struct SuggestionChip: View {
    let label: String
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label.isRTL ? rtlEmbedded(label) : label)
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}
