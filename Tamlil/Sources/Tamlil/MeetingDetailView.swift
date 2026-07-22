// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    /// Only shown when this view is a pushed navigation destination (the popover
    /// and window paths). The screenshot renderer hosts it bare, where a back
    /// button would dismiss nothing.
    let showsBackButton: Bool

    @State private var clarifications: [Clarification] = []
    @State private var transcriptText: String?
    @State private var segments: [TranscriptSegment] = []
    @State private var renaming = false
    @State private var renameText = ""
    @StateObject private var waveformPlayer = MeetingWaveformPlayer()

    init(meeting: Meeting, showsBackButton: Bool = false) {
        self.meeting = meeting
        self.showsBackButton = showsBackButton
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if showsBackButton {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to meetings")
                }
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                StateChip(meeting: meeting)
                headerActions
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            Divider()
            if meeting.isProcessing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(meeting.stageText.map { "Processing — \($0)" }
                         ?? "Processing — transcript will refresh here when ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    transcriptContent
                }
                .onChange(of: waveformPlayer.activeSegmentIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(segmentID(index), anchor: .center)
                    }
                }
            }
            if waveformPlayer.hasAudio {
                Divider()
                DualWaveformTransport(player: waveformPlayer)
            } else if audioUnavailable {
                Divider()
                Text("Audio for this recording is no longer available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .navigationTitle(meeting.displayTitle)
        .onAppear { reload() }
        .onChange(of: meeting.meta.state) { _, _ in reload() }
    }

    /// One disk read per state change, not one per body evaluation.
    private func reload() {
        clarifications = ClarificationStore.load(in: meeting.directory)
        transcriptText = try? String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        segments = loadSegments() ?? []
        waveformPlayer.load(directory: meeting.directory, segments: segments)
    }

    private var metaLine: String {
        var parts = [Meeting.displayDateFormatter.string(from: meeting.meta.startedAt)]
        if let d = meeting.durationText { parts.append(d) }
        if let annotation = engineAnnotation(meeting.meta.transcriptionEngine) {
            parts.append(annotation)
        }
        return parts.joined(separator: " · ")
    }

    /// A finalized recording whose audio has since been reclaimed (compaction or
    /// cleanup) — show a note where the player would be instead of a blank gap.
    private var audioUnavailable: Bool {
        switch meeting.phase {
        case .ready, .needsClarification: return !waveformPlayer.hasAudio
        default: return false
        }
    }

    @ViewBuilder private var transcriptContent: some View {
        if !segments.isEmpty {
            InteractiveTranscriptView(
                segments: segments,
                clarifications: $clarifications,
                directory: meeting.directory,
                roster: meeting.meta.roster ?? [],
                activeSegmentIndex: waveformPlayer.activeSegmentIndex,
                playbackSync: waveformPlayer.playbackSync,
                stopOtherPlayback: { waveformPlayer.pause() },
                onSeek: { waveformPlayer.playSegment($0) },
                onReRun: { state.reprocess(meeting) }
            )
            .padding(12)
        } else if let transcriptText {
            MarkdownLiteView(text: transcriptText)
                .padding(12)
        } else {
            pendingState
        }
    }

    private var pendingState: some View {
        VStack(spacing: 8) {
            Text(meeting.displayState)
                .foregroundStyle(.secondary)
            if case .error(let message) = meeting.phase {
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                Button("Retry pipeline") { state.reprocess(meeting) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 12)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                renameText = meeting.meta.eventTitle ?? ""
                renaming = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("Rename meeting")
            .popover(isPresented: $renaming, arrowEdge: .bottom) {
                RenamePopover(placeholder: meeting.autoTitle, text: $renameText) {
                    MeetingStore.rename(meeting.id, to: renameText)
                    renaming = false
                    state.refreshMeetings()
                }
            }
            Button {
                NSWorkspace.shared.open(meeting.directory)
            } label: {
                Image(systemName: "folder")
            }
            .help("Open recording folder")
            if transcriptText != nil {
                Button { copyTranscript() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy transcript")
                Menu {
                    Button("Markdown (.md)") { exportTranscript(.markdown) }
                    Button("Plain text (.txt)") { exportTranscript(.plainText) }
                    Button("PDF (.pdf)") { exportTranscript(.pdf) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuIndicator(.hidden)
                .help("Export transcript")
            }
            Button {
                state.reprocess(meeting)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-run transcription pipeline")
            .disabled(state.isPipelineRunning(meeting))
        }
        .buttonStyle(.borderless)
    }

    private func copyTranscript() {
        let text: String
        if !segments.isEmpty {
            text = transcriptMarkdown(
                segments: segments,
                speakerNames: SpeakerNames.load(in: meeting.directory),
                roster: meeting.meta.roster ?? [],
                meFullName: NSFullUserName())
        } else if let raw = try? String(contentsOf: meeting.transcriptURL, encoding: .utf8) {
            text = raw
        } else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func loadSegments() -> [TranscriptSegment]? {
        let url = meeting.paths.finalTranscriptJSON
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(TranscriptDoc.self, from: data)
        else { return nil }
        return doc.segments
    }

    private enum ExportFormat { case markdown, plainText, pdf }

    /// Best transcript Markdown: rebuilt from segments with resolved speakers,
    /// else the raw transcript.md — the same source the copy button uses.
    private func exportMarkdown() -> String? {
        if !segments.isEmpty {
            return transcriptMarkdown(
                segments: segments,
                speakerNames: SpeakerNames.load(in: meeting.directory),
                roster: meeting.meta.roster ?? [],
                meFullName: NSFullUserName())
        }
        return try? String(contentsOf: meeting.transcriptURL, encoding: .utf8)
    }

    /// Plain "Speaker: text" transcript with resolved speakers; falls back to the
    /// raw markdown when segments are unavailable.
    private func plainTextTranscript() -> String? {
        guard !segments.isEmpty else { return exportMarkdown() }
        let names = SpeakerNames.load(in: meeting.directory)
        let roster = meeting.meta.roster ?? []
        let me = NSFullUserName()
        let voiceCounts = voiceCountsByTrack(segments)
        let lines = segments.sorted { $0.start < $1.start }.map { seg in
            (speaker: speakerDisplayName(speaker: seg.speaker, voice: seg.voice,
                                         names: names, voiceCounts: voiceCounts,
                                         roster: roster, meFullName: me)
                ?? seg.speaker ?? "?",
             text: seg.text)
        }
        return transcriptPlainText(lines: lines)
    }

    private func exportTranscript(_ format: ExportFormat) {
        let base = meeting.displayTitle.replacingOccurrences(of: "/", with: "-")
        switch format {
        case .markdown:
            guard let md = exportMarkdown() else { return }
            saveExport(Data(md.utf8), suggestedName: "\(base).md")
        case .plainText:
            guard let text = plainTextTranscript() else { return }
            saveExport(Data(text.utf8), suggestedName: "\(base).txt")
        case .pdf:
            guard let text = plainTextTranscript() else { return }
            saveExport(transcriptPDFData(text), suggestedName: "\(base).pdf")
        }
    }
}

private func segmentID(_ index: Int) -> String {
    "segment-\(index)"
}

/// A free-form rename field for a meeting title. The placeholder shows the
/// automatic title; submitting an empty field restores it.
struct RenamePopover: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit(onSubmit)
            Button("Save", action: onSubmit)
        }
        .padding(10)
        .onAppear { focused = true }
    }
}

func engineAnnotation(_ engine: String?) -> String? {
    nil
}

struct StateChip: View {
    let meeting: Meeting

    var body: some View {
        Text(meeting.displayState)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(meeting.stateColor.opacity(0.16), in: Capsule())
            .foregroundStyle(meeting.stateColor)
    }
}

struct TranscriptDoc: Codable {
    let segments: [TranscriptSegment]
}

// Not Identifiable: start times can collide across speakers, so identity is
// the segment's position in the document order.
struct TranscriptWord: Codable, Equatable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double?
    let language: String?
    let speaker: String?

    init(text: String, start: Double, end: Double,
         confidence: Double? = nil, language: String? = nil, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.language = language
        self.speaker = speaker
    }
}

struct TranscriptSegment: Codable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
    let words: [TranscriptWord]?
    /// Diarized voice id within the track ("1", "2", ...), from the engine.
    let voice: String?
    let audioStart: Double?
    let audioEnd: Double?
    var playbackStart: Double { audioStart ?? start }
    var playbackEnd: Double { audioEnd ?? end }

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case text
        case speaker
        case words
        case voice
        case audioStart = "audio_start"
        case audioEnd = "audio_end"
    }

    var timestamp: String {
        timestampText(for: start)
    }
}

func timestampText(for seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

func transcriptTimestamp(for segment: TranscriptSegment, sync: PlaybackSync) -> String {
    timestampText(for: sync.displayStart(for: segment))
}

/// Markdown for the copy button: matches what the transcript view shows,
/// resolving each line's speaker through diarization, renames, and roster
/// rather than the raw track labels the pipeline writes into transcript.md.
func transcriptMarkdown(segments: [TranscriptSegment], speakerNames: [String: String],
                        roster: [String], meFullName: String) -> String {
    let voiceCounts = voiceCountsByTrack(segments)
    var lines = ["# Transcript", ""]
    for seg in segments.sorted(by: { $0.start < $1.start }) {
        let speaker = speakerDisplayName(
            speaker: seg.speaker, voice: seg.voice, names: speakerNames,
            voiceCounts: voiceCounts, roster: roster, meFullName: meFullName)
            ?? seg.speaker ?? "?"
        lines.append("**[\(timestampText(for: seg.start))] \(speaker):** \(seg.text)")
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

func transcriptDisplayOrder(for segments: [TranscriptSegment],
                            sync: PlaybackSync) -> [Int] {
    segments.indices.sorted { lhs, rhs in
        let left = sync.displayStart(for: segments[lhs])
        let right = sync.displayStart(for: segments[rhs])
        if left == right { return lhs < rhs }
        return left < right
    }
}

func roundedSeconds(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

func wordAudioRange(for target: String, in words: [TranscriptWord]?,
                    segmentStart: Double, segmentEnd: Double) -> (start: Double, end: Double)? {
    let targetCores = target.split(separator: " ")
        .map { splitToken(String($0)).core.lowercased() }
        .filter { !$0.isEmpty }
    guard let words, !targetCores.isEmpty, words.count >= targetCores.count else { return nil }
    let wordCores = words.map { splitToken($0.text).core.lowercased() }
    for i in 0...(words.count - targetCores.count)
    where Array(wordCores[i..<(i + targetCores.count)]) == targetCores {
        return (roundedSeconds(max(segmentStart, words[i].start - 0.3)),
                roundedSeconds(min(segmentEnd, words[i + targetCores.count - 1].end + 0.3)))
    }
    return nil
}

/// The transcript IS the correction surface. Each line reads as prose with
/// uncertain terms underlined by severity (red squiggle = likely wrong, gray
/// dots = minor doubt); clicking a flag or selecting text opens a spellcheck
/// style correction popup. Accepting a fix writes it to the dictionary +
/// glossary and shows the corrected line; "Apply & re-run" re-runs the
/// pipeline to apply everything.
struct InteractiveTranscriptView: View {
    let segments: [TranscriptSegment]
    @Binding var clarifications: [Clarification]
    let directory: URL
    let roster: [String]
    let activeSegmentIndex: Int?
    let playbackSync: PlaybackSync
    var stopOtherPlayback: () -> Void
    var onSeek: (Int) -> Void
    var onReRun: () -> Void

    @State private var editedThisSession = false
    @State private var dictionary = LexiconDictionary.empty
    @State private var speakerNames: [String: String] = [:]

    var body: some View {
        let attrib = attribution
        let resolved = unappliedResolvedEdits
        let shown = attrib.values.flatMap { $0 }
        let voiceCounts = voiceCountsByTrack(segments)
        let me = NSFullUserName()
        return VStack(alignment: .leading, spacing: 12) {
            reviewHeader(total: shown.count,
                         important: shown.filter(\.isWrong).count,
                         hasUnapplied: !resolved.isEmpty)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(transcriptDisplayOrder(for: segments, sync: playbackSync), id: \.self) { index in
                    let seg = segments[index]
                    TranscriptLineView(
                        seg: seg,
                        chip: chip(for: seg, voiceCounts: voiceCounts, me: me),
                        flags: attrib[index] ?? [],
                        initialEdits: resolved[index] ?? [],
                        dictionary: dictionary,
                        directory: directory,
                        isActive: activeSegmentIndex == index,
                        timestamp: transcriptTimestamp(for: seg, sync: playbackSync),
                        stopOtherPlayback: stopOtherPlayback,
                        onSeek: { onSeek(index) },
                        onResolve: resolve(ids:edits:adding:)
                    )
                    .id(segmentID(index))
                }
            }
        }
        .onAppear {
            if let repo = PipelineRunner.resolvedRepo() {
                dictionary = LexiconDictionary.load(
                    from: repo.appendingPathComponent("dictionary.json"))
            }
            speakerNames = SpeakerNames.load(in: directory)
        }
    }

    private func chip(for seg: TranscriptSegment, voiceCounts: [String: Int],
                      me: String) -> SpeakerChip? {
        guard let name = speakerDisplayName(
            speaker: seg.speaker, voice: seg.voice, names: speakerNames,
            voiceCounts: voiceCounts, roster: roster, meFullName: me)
        else { return nil }
        return SpeakerChip(name: name, isThem: seg.speaker == "Them",
                           renamableVoice: renamableVoice(
                               speaker: seg.speaker, voice: seg.voice,
                               voiceCounts: voiceCounts),
                           roster: roster,
                           onRename: rename(voice:to:))
    }

    private func rename(voice: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            speakerNames.removeValue(forKey: voice)
        } else {
            speakerNames[voice] = trimmed
        }
        SpeakerNames.save(speakerNames, in: directory)
    }

    @ViewBuilder private func reviewHeader(total: Int, important: Int,
                                           hasUnapplied: Bool) -> some View {
        let showApply = editedThisSession || hasUnapplied
        if total > 0 || showApply {
            HStack(spacing: 8) {
                if total > 0 {
                    Image(systemName: "pencil.and.outline").foregroundStyle(.secondary)
                    Text("\(total) to review").font(.caption).foregroundStyle(.secondary)
                    if important > 0 {
                        Text("\(important) important")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.red.opacity(0.16), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if showApply {
                    Button("Apply & re-run", action: onReRun)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.bottom, 2)
        }
    }

    /// Each pending flag attached to the one segment it was located in (by time,
    /// confirmed by text), keyed by segment index. Flags whose term isn't in the
    /// corrected transcript (already fixed, or malformed) aren't shown — there's
    /// nothing to correct.
    private var attribution: [Int: [Clarification]] {
        var map: [Int: [Clarification]] = [:]
        var used = Set<String>()
        for (index, seg) in segments.enumerated() {
            for f in clarifications where f.isPending && !used.contains(f.id) {
                guard let s = f.start else { continue }
                if s >= seg.start - 0.05, s <= seg.end + 0.05,
                   tokenBoundaryRange(of: f.original, in: seg.text) != nil {
                    map[index, default: []].append(f)
                    used.insert(f.id)
                }
            }
        }
        return map
    }

    /// Confirmed fixes that no pipeline re-run has applied yet — their "from"
    /// tokens still appear in the segment — keyed by segment index. Seeding the
    /// line views from these keeps resolved edits visible (and the re-run CTA
    /// up) across view recreation.
    private var unappliedResolvedEdits: [Int: [(String, String)]] {
        var map: [Int: [(String, String)]] = [:]
        for (index, seg) in segments.enumerated() {
            var edits: [(String, String)] = []
            for f in clarifications where f.status == "resolved" {
                guard let s = f.start, s >= seg.start - 0.05, s <= seg.end + 0.05
                else { continue }
                edits += f.resolvedEdits.filter { containsTokenMatch(in: seg.text, of: $0.0) }
            }
            if !edits.isEmpty { map[index] = edits }
        }
        return map
    }

    private func resolve(ids: [String], edits: [(String, String)], adding synthetic: Clarification?) {
        if let synthetic { clarifications.append(synthetic) }
        for i in clarifications.indices where ids.contains(clarifications[i].id) {
            clarifications[i].status = "resolved"
            clarifications[i].answer = Clarification.answerSummary(edits)
            clarifications[i].edits = edits.map { [$0.0, $0.1] }
        }
        editedThisSession = true
        ClarificationStore.save(clarifications, in: directory)
    }
}

struct TranscriptLineView: View {
    let seg: TranscriptSegment
    /// Speaker identity UI, fully assembled by the parent; nil = unlabeled.
    let chip: SpeakerChip?
    /// Pending flags attributed to this line (the parent filters by status).
    let flags: [Clarification]
    let dictionary: LexiconDictionary
    let directory: URL
    let isActive: Bool
    let timestamp: String
    var stopOtherPlayback: () -> Void
    var onSeek: () -> Void
    var onResolve: (_ ids: [String], _ edits: [(String, String)],
                    _ synthetic: Clarification?) -> Void

    @State private var localEdits: [(String, String)]
    @State private var hit: TextHit?
    private let initialEdits: [(String, String)]

    init(seg: TranscriptSegment, chip: SpeakerChip?, flags: [Clarification],
         initialEdits: [(String, String)], dictionary: LexiconDictionary,
         directory: URL, isActive: Bool, timestamp: String,
         stopOtherPlayback: @escaping () -> Void,
         onSeek: @escaping () -> Void,
         onResolve: @escaping (_ ids: [String], _ edits: [(String, String)],
                               _ synthetic: Clarification?) -> Void) {
        self.seg = seg
        self.chip = chip
        self.flags = flags
        self.dictionary = dictionary
        self.directory = directory
        self.isActive = isActive
        self.timestamp = timestamp
        self.stopOtherPlayback = stopOtherPlayback
        self.onSeek = onSeek
        self.onResolve = onResolve
        self.initialEdits = initialEdits
        // Confirmed-but-not-yet-reprocessed fixes survive view recreation.
        _localEdits = State(initialValue: initialEdits)
    }

    private var isResolved: Bool { !localEdits.isEmpty }

    /// The line as currently corrected; flags are re-located against this
    /// text, so an accepted fix's underline disappears with the term.
    private var displayText: String {
        var out = seg.text
        for e in localEdits {
            out = replacingTokenMatches(in: out, of: e.0, with: e.1)
        }
        return out
    }

    var body: some View {
        let text = displayText
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            SelectableTextView(text: text,
                               flags: flagDisplayRanges(flags, in: text),
                               onHit: { hit = $0 })
                .popover(item: $hit,
                         attachmentAnchor: .rect(.rect(hit?.rect ?? .zero)),
                         arrowEdge: .bottom) { presented in
                    popup(for: presented)
                }
                .padding(.horizontal, isResolved ? 8 : 0)
                .padding(.vertical, isResolved ? 5 : 0)
                .background(isResolved ? Color.green.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSeek)
        // A pipeline re-run rewrites this slot's text; this LazyVStack row is
        // reused (id = index), so reset the cached edit state to what's on disk
        // instead of keeping stale edits from the previous transcript.
        .onChange(of: seg.text) { _, _ in
            localEdits = initialEdits
            hit = nil
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let chip {
                chip
            }
            Spacer()
            if isResolved {
                Label("edited", systemImage: "pencil")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }


    @ViewBuilder private func popup(for presented: TextHit) -> some View {
        let flag = flagFor(presented)
        CorrectionPopover(
            heard: presented.text,
            suggestions: dictionary.suggestions(for: presented.text, guess: flag?.guess),
            audio: audioSlice(for: presented, flag: flag),
            stopOtherPlayback: stopOtherPlayback,
            onAccept: { accept(heard: presented.text, flag: flag, correction: $0) },
            onClose: { hit = nil }
        )
    }

    private func flagFor(_ hit: TextHit) -> Clarification? {
        guard case .flag(let id) = hit.kind else { return nil }
        return flags.first { $0.id == id }
    }

    private func audioSlice(for hit: TextHit, flag: Clarification?) -> AudioSlice? {
        let speaker = flag?.speaker ?? seg.speaker
        guard let url = meetingAudioURL(speaker: speaker, in: directory) else { return nil }
        let idPrefix = flag.map { "flag-\($0.id)" } ?? "selection-\(hit.id)"
        if let range = wordAudioRange(for: hit.text, in: seg.words,
                                      segmentStart: seg.playbackStart,
                                      segmentEnd: seg.playbackEnd) {
            return AudioSlice(id: "\(idPrefix)-word", url: url,
                              start: range.start, end: range.end)
        }
        return AudioSlice(id: "\(idPrefix)-segment", url: url,
                          start: seg.playbackStart, end: seg.playbackEnd)
    }

    private func accept(heard: String, flag: Clarification?, correction: String) {
        hit = nil
        let fix = correction.trimmingCharacters(in: .whitespaces)
        guard !fix.isEmpty, fix != heard else { return }
        let before = displayText
        // A mid-word selection can't be replaced (token matching is whole-word)
        // — accepting it would only pollute the lexicon with a junk pair.
        guard containsTokenMatch(in: before, of: heard) else { return }
        ClarificationStore.confirm(original: heard, corrected: fix)
        let ids = (flag.map { [$0.id] } ?? [])
            + swallowedFlagIDs(replacing: heard, with: fix, in: before,
                               among: flags.filter { $0.id != flag?.id })
        // A selection that resolves no flag has no clarification to carry it
        // across view recreation; record a synthetic resolved one so the edit
        // and the re-run CTA survive until the pipeline applies it.
        let synthetic: Clarification? = ids.isEmpty
            ? .resolvedRecord(heard: heard, fix: fix, context: seg.text,
                              start: seg.start, end: seg.end, speaker: seg.speaker)
            : nil
        localEdits.append((heard, fix))
        onResolve(ids, [(heard, fix)], synthetic)
    }
}

/// Renders simple markdown: headers, nested
/// bullets, checkboxes, inline bold/italic/code — RTL-correct for Hebrew.
struct MarkdownLiteView: View {
    let text: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                    id: \.offset) { _, raw in
                let s = String(raw)
                // Per-line direction: under a RTL layout direction, .leading
                // resolves to the right edge, bullets flip, and .leading
                // indent pads from the right.
                line(s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection,
                                 visibleText(s).isRTL ? .rightToLeft : .leftToRight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// The line's text with markdown list/heading markers stripped, so a
    /// checkbox's "x" doesn't decide the direction of a Hebrew item.
    private func visibleText(_ raw: String) -> String {
        let stripped = String(raw.drop(while: { $0 == " " }))
        for marker in ["- [ ] ", "- [x] ", "### ", "## ", "# ", "- ", "* "]
        where stripped.hasPrefix(marker) {
            return String(stripped.dropFirst(marker.count))
        }
        return stripped
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let stripped = raw.drop(while: { $0 == " " })
        let indent = CGFloat((raw.count - stripped.count) / 2) * 14
        let body = String(stripped)

        if body.hasPrefix("# ") {
            inline(String(body.dropFirst(2)))
                .font(.title3.bold())
                .padding(.top, 2)
        } else if body.hasPrefix("## ") {
            VStack(alignment: .leading, spacing: 3) {
                inline(String(body.dropFirst(3)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
            }
            .padding(.top, 10)
        } else if body.hasPrefix("### ") {
            inline(String(body.dropFirst(4)))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
        } else if body.hasPrefix("- [ ] ") || body.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: body.hasPrefix("- [x]") ? "checkmark.square.fill" : "square")
                    .font(.subheadline)
                    .foregroundStyle(body.hasPrefix("- [x]") ? Color.accentColor : Color.secondary)
                inline(String(body.dropFirst(6)))
            }
            .padding(.leading, indent)
        } else if body.hasPrefix("- ") || body.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(indent > 0 ? "◦" : "•")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                inline(String(body.dropFirst(2)))
            }
            .padding(.leading, indent)
        } else if body.hasPrefix("|") {
            inline(body).font(.system(.caption, design: .monospaced))
        } else if body == "None" || body == "None." {
            Text("None")
                .font(.callout.italic())
                .foregroundStyle(.tertiary)
        } else if body.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else {
            inline(body)
        }
    }

    /// Parse inline markdown FIRST, then wrap RTL lines in RLE/PDF — bidi
    /// control characters adjacent to ** break CommonMark's flanking rules,
    /// leaving literal asterisks (seen with bold at line start).
    private func inline(_ s: String) -> Text {
        let parsed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        guard s.isRTL else { return Text(parsed) }
        return Text(AttributedString("\u{202B}") + parsed + AttributedString("\u{202C}"))
    }
}
