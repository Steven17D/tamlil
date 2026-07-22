// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI

/// Per-meeting names for diarized voices on the system track.
enum SpeakerNames {
    static func load(in directory: URL) -> [String: String] {
        MeetingStore.speakerNames(for: RecordingID(directory.lastPathComponent))
    }

    static func save(_ names: [String: String], in directory: URL) {
        MeetingStore.saveSpeakerNames(names, for: RecordingID(directory.lastPathComponent))
    }
}

/// Display name for a transcript line's speaker chip. Mirrors the pipeline's
/// speaker_labels.label.
///
/// A user-assigned name for the voice wins on any track. A "Them" voice then
/// falls back to the sole other roster attendee when that is unambiguous. An
/// unnamed voice shows "Speaker N" only when its own track heard several
/// voices — so a solo mic track stays the local user's name, while a shared
/// room (several diarized voices on the mic) gets tellable-apart, renamable
/// lines just like system voices.
func speakerDisplayName(speaker: String?, voice: String?, names: [String: String],
                        voiceCounts: [String: Int], roster: [String],
                        meFullName: String) -> String? {
    guard let speaker else { return nil }
    if let voice {
        if let named = names[voice] { return named }
        if speaker == "Them" {
            let full = meFullName.lowercased()
            let local = full.split(separator: " ").first.map(String.init) ?? full
            let others = roster.filter { $0.lowercased() != local && !full.contains($0.lowercased()) }
            if others.count == 1 { return others[0] }
        }
        if voiceCounts[speaker, default: 0] > 1 { return "Speaker \(voice)" }
    } else if speaker == "Them" {
        let full = meFullName.lowercased()
        let local = full.split(separator: " ").first.map(String.init) ?? full
        let others = roster.filter { $0.lowercased() != local && !full.contains($0.lowercased()) }
        if others.count == 1 { return others[0] }
    }
    return speaker
}

/// Distinct diarized voices per track ("speaker" identity), the counts
/// speakerDisplayName keys on.
func voiceCountsByTrack(_ segments: [TranscriptSegment]) -> [String: Int] {
    var voices: [String: Set<String>] = [:]
    for seg in segments {
        if let speaker = seg.speaker, let voice = seg.voice {
            voices[speaker, default: []].insert(voice)
        }
    }
    return voices.mapValues(\.count)
}

/// The voice a line's chip may rename: any system voice, or a mic voice when
/// the mic heard several people (a shared room). A solo mic line is the local
/// user and is not renamable.
func renamableVoice(speaker: String?, voice: String?,
                    voiceCounts: [String: Int]) -> String? {
    guard let speaker, let voice else { return nil }
    if speaker == "Them" { return voice }
    return voiceCounts[speaker, default: 0] > 1 ? voice : nil
}

/// Speaker label on a transcript line. For a diarized "Them" voice it is a
/// button opening the rename popover; the assigned name applies to every line
/// of that voice in the meeting.
struct SpeakerChip: View {
    let name: String
    let isThem: Bool
    let renamableVoice: String?
    let roster: [String]
    var onRename: (_ voice: String, _ name: String) -> Void

    @State private var renaming = false

    var body: some View {
        let label = Text(name)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((isThem ? Color.secondary : Color.accentColor)
                .opacity(0.18), in: Capsule())
        if let voice = renamableVoice {
            Button { renaming = true } label: { label }
                .buttonStyle(.plain)
                .help("Name this speaker")
                .popover(isPresented: $renaming, arrowEdge: .bottom) {
                    SpeakerRenamePopover(current: name, roster: roster) { newName in
                        renaming = false
                        onRename(voice, newName)
                    }
                }
        } else {
            label
        }
    }
}

/// Rename bar for a diarized voice: tappable roster suggestions plus a
/// free-form field. Submitting an empty field clears the assigned name.
struct SpeakerRenamePopover: View {
    let current: String
    let roster: [String]
    var onName: (String) -> Void

    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(roster, id: \.self) { attendee in
                SuggestionChip(label: attendee) { onName(attendee) }
            }
            TextField(current, text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 120)
                .focused($fieldFocused)
                .onSubmit { onName(name) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { fieldFocused = roster.isEmpty }
    }
}
