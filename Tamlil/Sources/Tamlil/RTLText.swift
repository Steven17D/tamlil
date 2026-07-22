// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Shared right-to-left text helpers. Mixed Hebrew/English views detect
/// direction per line with `isRTL` and embed RTL lines with `rtlEmbedded`;
/// LTR lines are left untouched so their punctuation stays put.

extension String {
    /// True when the line holds any Hebrew/Arabic strong character, so it reads
    /// and aligns right-to-left. Any Hebrew wins: a mostly-English sentence with
    /// a Hebrew clause still belongs on the right, and only a fully non-Hebrew
    /// line stays left-to-right.
    var isRTL: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            default: return false
            }
        }
    }
}

/// Wrap a line in RLE...PDF so its bidi base direction is right-to-left no
/// matter what it starts with — Hebrew sentences opening with an English term
/// otherwise render with scrambled word order.
func rtlEmbedded(_ s: String) -> String {
    "\u{202B}\(s)\u{202C}"
}
