// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Read-only view of the repo's dictionary.json (lexicon.py owns the format):
/// canonical terms plus the garbled variants they were learned from. The
/// correction popup uses it to suggest the canonical when a flagged or
/// selected phrase matches a known variant.
struct LexiconDictionary {
    let variantToCanonical: [String: String]

    static let empty = LexiconDictionary(variantToCanonical: [:])

    /// Edge characters stripped from a match key — keep in sync with
    /// lexicon.py's _EDGE.
    private static let edge = CharacterSet(charactersIn: " \t\r\n.,!?;:\"'()[]{}…-–—")

    /// Match key mirroring lexicon.py's _norm: trimmed, edge-depunctuated,
    /// whitespace-collapsed, lowercased — so a selection like "EB two," still
    /// finds the stored variant "eb two".
    static func matchKey(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: edge)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Missing or malformed file is an empty dictionary, never an error —
    /// suggestions just degrade to the model's guess.
    static func load(from url: URL) -> LexiconDictionary {
        struct Doc: Decodable {
            struct Term: Decodable {
                let canonical: String
                let variants: [String]
            }
            let terms: [Term]
        }
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Doc.self, from: data)
        else { return .empty }
        var map: [String: String] = [:]
        for term in doc.terms {
            for variant in term.variants {
                map[matchKey(variant)] = term.canonical
            }
        }
        return LexiconDictionary(variantToCanonical: map)
    }

    /// The canonical for a phrase whose match key hits a known variant,
    /// unless the phrase already is that canonical.
    func canonical(for phrase: String) -> String? {
        let key = Self.matchKey(phrase)
        guard let c = variantToCanonical[key], Self.matchKey(c) != key else { return nil }
        return c
    }

    /// Popup suggestions for a heard phrase: the model's guess first, then the
    /// dictionary canonical — deduplicated case-insensitively and never echoing
    /// the phrase itself.
    func suggestions(for phrase: String, guess: String?) -> [String] {
        var out: [String] = []
        var seen: Set<String> = [Self.matchKey(phrase)]
        for candidate in [guess, canonical(for: phrase)] {
            guard let c = candidate?.trimmingCharacters(in: .whitespaces), !c.isEmpty,
                  seen.insert(Self.matchKey(c)).inserted else { continue }
            out.append(c)
        }
        return out
    }
}
