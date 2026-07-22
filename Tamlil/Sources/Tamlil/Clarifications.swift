// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One "did you mean...?" question from the correction model.
/// Stored in SQLite; answers feed the repo-level dictionary.json (applied on
/// every future correction) and terms.txt (biases the ASR decoder itself).
struct Clarification: Codable, Identifiable {
    var original: String
    var guess: String?
    var context: String
    var status: String          // pending | resolved | skipped
    var severity: String?       // "wrong" (confident error) | "unsure" (minor doubt)
    var answer: String?         // summary of the heard->correction edits
    var edits: [[String]]?      // [[from, to], ...] applied on confirm
    // Where the term was spoken, set by the pipeline; nil if it couldn't locate it.
    var start: Double?
    var end: Double?
    var speaker: String?
    var source: String?
    var confidence: Double?
    var id: String { original + context }
    var isPending: Bool { status == "pending" }
    /// Confident error worth acting on, vs a minor doubt to skim. Unknown
    /// (older data without the field) is treated as a minor doubt.
    var isWrong: Bool { severity == "wrong" }

    /// The context line with all confirmed edits applied. Backfills from the
    /// answer summary for cards resolved before `edits` was stored.
    var correctedSentence: String {
        var line = context
        for (from, to) in resolvedEdits {
            line = replacingTokenMatches(in: line, of: from, with: to)
        }
        return line
    }

    var resolvedEdits: [(String, String)] {
        if let edits {
            let pairs = edits.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
            // A present-but-malformed edits array (wrong arity, or empty) still
            // backfills from the answer summary rather than rendering unedited.
            if !pairs.isEmpty { return pairs }
        }
        guard let answer else { return [] }
        let parsed = answer.components(separatedBy: ", ").compactMap {
            (chunk: String) -> (String, String)? in
            let parts = chunk.components(separatedBy: " → ")
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        // Oldest format: answer is just the bare correction for `original`.
        if parsed.isEmpty, !answer.isEmpty { return [(original, answer)] }
        return parsed
    }

    /// The slice's audio, or nil if the term was never located in a track.
    /// `fallbackSpeaker` covers flags stored without speaker attribution.
    func audioURL(in directory: URL, fallbackSpeaker: String? = nil) -> URL? {
        start == nil ? nil : meetingAudioURL(speaker: speaker ?? fallbackSpeaker, in: directory)
    }

    /// Canonical "heard → fix" answer summary. `resolvedEdits` parses this
    /// exact format back for cards resolved before `edits` was stored, so it
    /// must be built in one place.
    static func answerSummary(_ edits: [(String, String)]) -> String {
        edits.map { "\($0.0) → \($0.1)" }.joined(separator: ", ")
    }

    /// A user-confirmed selection edit recorded as an already-resolved card:
    /// no model question behind it, but a resolved card is the one shape that
    /// persists "edit awaiting a pipeline run" across view recreation.
    static func resolvedRecord(heard: String, fix: String, context: String,
                               start: Double?, end: Double?,
                               speaker: String?) -> Clarification {
        Clarification(original: heard, guess: fix, context: context,
                      status: "resolved", severity: nil,
                      answer: answerSummary([(heard, fix)]), edits: [[heard, fix]],
                      start: start, end: end, speaker: speaker)
    }

}

/// A whitespace token split into leading punctuation, core word, and trailing
/// punctuation; an all-punctuation token is its own core so it never matches a
/// real word.
func splitToken(_ token: String) -> (lead: String, core: String, trail: String) {
    guard let first = token.firstIndex(where: { !$0.isPunctuation }),
          let last = token.lastIndex(where: { !$0.isPunctuation })
    else { return ("", token, "") }
    return (String(token[..<first]),
            String(token[first...last]),
            String(token[token.index(after: last)...]))
}

/// Whole-token phrase replacement: `from`'s words must match a contiguous run
/// of whitespace tokens (compared modulo surrounding punctuation), so fixing a
/// short word can never rewrite the inside of a longer one. Punctuation around
/// the matched run is preserved.
func replacingTokenMatches(in line: String, of from: String, with to: String) -> String {
    let fromCores = from.split(separator: " ").map { splitToken(String($0)).core }
    guard !fromCores.isEmpty else { return line }
    var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    let toTokens = to.split(separator: " ").map(String.init)
    var changed = false
    var i = 0
    while i + fromCores.count <= tokens.count {
        guard tokens[i..<(i + fromCores.count)].map({ splitToken($0).core }) == fromCores else {
            i += 1
            continue
        }
        var replacement = toTokens
        if !replacement.isEmpty {
            replacement[0] = splitToken(tokens[i]).lead + replacement[0]
            replacement[replacement.count - 1] += splitToken(tokens[i + fromCores.count - 1]).trail
        }
        tokens.replaceSubrange(i..<(i + fromCores.count), with: replacement)
        changed = true
        i += replacement.count
    }
    return changed ? tokens.joined(separator: " ") : line
}

/// Whether `phrase` matches a contiguous token run in `line` (same matching
/// rules as `replacingTokenMatches`).
func containsTokenMatch(in line: String, of phrase: String) -> Bool {
    let phraseCores = phrase.split(separator: " ").map { splitToken(String($0)).core }
    let lineCores = line.split(separator: " ", omittingEmptySubsequences: true)
        .map { splitToken(String($0)).core }
    guard !phraseCores.isEmpty, lineCores.count >= phraseCores.count else { return false }
    for i in 0...(lineCores.count - phraseCores.count)
    where Array(lineCores[i..<(i + phraseCores.count)]) == phraseCores {
        return true
    }
    return false
}

/// First occurrence of `phrase` sitting on token boundaries (line edges,
/// whitespace, or punctuation on both sides), so a short flagged term never
/// underlines the inside of a longer word.
func tokenBoundaryRange(of phrase: String, in text: String) -> Range<String.Index>? {
    guard !phrase.isEmpty else { return nil }
    var searchStart = text.startIndex
    while let r = text.range(of: phrase, range: searchStart..<text.endIndex) {
        let beforeOK = r.lowerBound == text.startIndex
            || isTokenBoundary(text[text.index(before: r.lowerBound)])
        let afterOK = r.upperBound == text.endIndex || isTokenBoundary(text[r.upperBound])
        if beforeOK && afterOK { return r }
        searchStart = text.index(after: r.lowerBound)
    }
    return nil
}

private func isTokenBoundary(_ c: Character) -> Bool {
    c.isWhitespace || c.isPunctuation
}

/// Flags located in `text`, each with the character range to underline.
/// Flags whose term isn't on a token boundary in the current text (already
/// fixed, or malformed) drop out — there's nothing to mark.
func flagDisplayRanges(_ flags: [Clarification], in text: String)
    -> [(flag: Clarification, range: Range<String.Index>)] {
    flags.compactMap { f in
        tokenBoundaryRange(of: f.original, in: text).map { (f, $0) }
    }
}

/// Flags whose term the heard→fix rewrite removes from `text`: once the term
/// is gone the flag can never be located or acted on again, so the accept
/// that destroyed it resolves it too instead of leaving a phantom
/// "to review" count.
func swallowedFlagIDs(replacing heard: String, with fix: String, in text: String,
                      among flags: [Clarification]) -> [String] {
    let after = replacingTokenMatches(in: text, of: heard, with: fix)
    return flags.filter {
        tokenBoundaryRange(of: $0.original, in: text) != nil
            && tokenBoundaryRange(of: $0.original, in: after) == nil
    }.map(\.id)
}

enum ClarificationStore {
    static func load(in directory: URL) -> [Clarification] {
        MeetingStore.clarifications(for: RecordingID(directory.lastPathComponent))
    }

    static func save(_ items: [Clarification], in directory: URL) {
        MeetingStore.saveClarifications(items, for: RecordingID(directory.lastPathComponent))
    }

    static func pendingCount(in directory: URL) -> Int {
        load(in: directory).filter(\.isPending).count
    }

    /// Same resolution as the pipeline so confirmations land in the repo it
    /// actually reads. `nil` until the user points Settings at a checkout that
    /// holds meeting_pipeline.py.
    @MainActor
    private static var repo: URL? { PipelineRunner.resolvedRepo() }

    /// Record a confirmed correction by appending it to the repo's learned.jsonl
    /// log. The pipeline's lexicon folds new lines into dictionary.json (canonical
    /// term + variants + use count) and applies them deterministically on every
    /// future run. Append-only so the lexicon can ingest idempotently by offset.
    @MainActor
    static func confirm(original: String, corrected: String) {
        let rec: [String: String] = [
            "heard": original,
            "correct": corrected,
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: rec),
              let line = String(data: data, encoding: .utf8) else { return }
        guard let repo else {
            Notifier.notify(title: "Couldn't save correction",
                            body: "Set your Tamlil repo in Settings first.")
            return
        }
        let url = repo.appendingPathComponent("learned.jsonl")
        let payload = Data((line + "\n").utf8)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: url)
            }
        } catch {
            NSLog("learned.jsonl append failed: \(error)")
            Notifier.notify(title: "Couldn't save correction",
                            body: "\(original) → \(corrected): \(error.localizedDescription)")
        }
    }
}
