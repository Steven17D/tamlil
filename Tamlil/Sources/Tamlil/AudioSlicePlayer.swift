// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import SwiftUI

/// The track a given speaker was recorded on: "Them" is the system capture,
/// anyone else is the mic. Prefers the denoised mic so fan/AC hum doesn't drown
/// the slice. Shared by clarification cards and transcript lines.
func meetingAudioURL(speaker: String?, in directory: URL) -> URL? {
    let paths = RecordingPaths(root: directory.deletingLastPathComponent(),
                               id: RecordingID(directory.lastPathComponent))
    let candidates = speaker == "Them"
        ? [paths.rawSystemAudio]
        : [paths.workMicDenoisedAudio, paths.rawMicAudio]
    for url in candidates {
        if let found = existingAudio(for: url) { return found }
    }
    return nil
}

/// One audio slice (a [start, end] window of a wav) with a stable identity
/// for play/stop button state.
struct AudioSlice: Equatable {
    let id: String
    let url: URL
    let start: Double
    let end: Double
}

struct AudioSlicePlaybackState: Equatable {
    var playingID: String?
}

@discardableResult
func prepareAudioSliceToggle(
    state: inout AudioSlicePlaybackState,
    id: String,
    stopOtherPlayback: () -> Void
) -> Bool {
    if state.playingID == id {
        state.playingID = nil
        return false
    }
    stopOtherPlayback()
    state.playingID = id
    return true
}

/// The standard play/stop toggle for an audio slice — transcript lines and
/// the correction popover share one look and one player.
struct AudioSliceButton: View {
    let slice: AudioSlice
    var help: String
    var stopOtherPlayback: () -> Void = {}

    @ObservedObject private var player = AudioSlicePlayer.shared

    var body: some View {
        Button {
            player.toggle(id: slice.id, url: slice.url, start: slice.start, end: slice.end,
                          stopOtherPlayback: stopOtherPlayback)
        } label: {
            Image(systemName: player.playingID == slice.id ? "stop.circle" : "play.circle")
                .foregroundStyle(player.playingID == slice.id ? Color.red : Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Plays a [start, end] slice of a wav file — lets you hear what was actually
/// said. One shared player; starting a new slice stops the previous one.
/// `playingID` drives the play/stop button state.
@MainActor
final class AudioSlicePlayer: ObservableObject {
    static let shared = AudioSlicePlayer()

    @Published private(set) var playingID: String?

    private var player: AVAudioPlayer?
    private var stopWork: DispatchWorkItem?
    private let pad = 0.4  // seconds of lead-in/out so the word isn't clipped

    func toggle(id: String, url: URL, start: Double, end: Double,
                stopOtherPlayback: () -> Void = {}) {
        var state = AudioSlicePlaybackState(playingID: playingID)
        guard prepareAudioSliceToggle(state: &state, id: id,
                                      stopOtherPlayback: stopOtherPlayback)
        else {
            stop()
            return
        }
        play(id: id, url: url, start: start, end: end)
    }

    private func play(id: String, url: URL, start: Double, end: Double) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.currentTime = max(0, start - pad)
        p.play()
        playingID = id

        let duration = (end - start) + pad * 2
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        player = nil
        playingID = nil
    }
}
