// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import SwiftUI

struct MeetingPlaybackSources: Equatable {
    let mic: URL?
    let system: URL?
    let systemOffset: Double

    var urls: [URL] { [mic, system].compactMap { $0 } }
}

enum PlaybackTrack {
    case mic
    case system
}

struct PlaybackSync: Equatable {
    let systemOffset: Double

    func sourceTime(for track: PlaybackTrack, displayTime: Double, duration: Double) -> Double {
        let offset = track == .system ? systemOffset : 0
        return max(0, min(displayTime + offset, duration))
    }

    func displayStart(for segment: TranscriptSegment) -> Double {
        displayTime(for: segment, sourceTime: segment.playbackStart)
    }

    func displayEnd(for segment: TranscriptSegment) -> Double {
        displayTime(for: segment, sourceTime: segment.playbackEnd)
    }

    private func displayTime(for segment: TranscriptSegment, sourceTime: Double) -> Double {
        guard segment.speaker == "Them" else { return sourceTime }
        return max(0, sourceTime - systemOffset)
    }
}

struct PlaybackMix: Equatable {
    let micVolume: Float
    let systemVolume: Float
}

/// ASR start timestamps stamp the first recognized word, so the true onset
/// (breath, first consonant) sits just before the segment; the 100 ms mix
/// timer then flips the volume late on top. Opening the mic channel this far
/// ahead of a user segment keeps the onset audible.
let playbackMicLeadIn: Double = 0.35

func playbackMix(
    at time: Double,
    in segments: [TranscriptSegment],
    sync: PlaybackSync
) -> PlaybackMix {
    let micMix = PlaybackMix(micVolume: 1, systemVolume: 0)
    let systemMix = PlaybackMix(micVolume: 0, systemVolume: 1)
    if let index = activeTranscriptSegment(at: time, in: segments, sync: sync),
       segments[index].speaker != "Them" {
        return micMix
    }
    // A user segment about to start wins even over a still-active remote
    // segment: it only cedes the remote's tail, which ASR pads late anyway,
    // while the user's clipped onset is unrecoverable.
    let upcomingMic = segments.contains { seg in
        seg.speaker != "Them"
            && time >= sync.displayStart(for: seg) - playbackMicLeadIn
            && time < sync.displayStart(for: seg)
    }
    return upcomingMic ? micMix : systemMix
}

struct MeetingWaveform: Equatable {
    let label: String
    let color: Color
    let buckets: [Double]
    let duration: Double
    let isAvailable: Bool
}

func meetingPlaybackSources(in directory: URL) -> MeetingPlaybackSources? {
    let paths = RecordingPaths(root: directory.deletingLastPathComponent(),
                               id: RecordingID(directory.lastPathComponent))
    let mic = existingAudio(for: paths.workMicDenoisedAudio)
        ?? existingAudio(for: paths.rawMicAudio)
    let system = existingAudio(for: paths.rawSystemAudio)
    guard mic != nil || system != nil else { return nil }
    return MeetingPlaybackSources(mic: mic, system: system,
                                  systemOffset: systemMicOffset(in: paths))
}

private struct EchoReport: Decodable {
    let systemMicOffset: Double?

    enum CodingKeys: String, CodingKey {
        case systemMicOffset = "system_mic_offset_s"
    }
}

private func systemMicOffset(in paths: RecordingPaths) -> Double {
    guard let data = try? Data(contentsOf: paths.workEchoReportJSON),
          let report = try? JSONDecoder().decode(EchoReport.self, from: data),
          let offset = report.systemMicOffset,
          offset.isFinite
    else { return 0 }
    return offset
}

func waveformBuckets(samples: [Float], bucketCount: Int) -> [Double] {
    guard bucketCount > 0, !samples.isEmpty else { return [] }
    return (0..<bucketCount).map { bucket in
        let start = bucket * samples.count / bucketCount
        let end = max(start + 1, (bucket + 1) * samples.count / bucketCount)
        let peak = samples[start..<min(end, samples.count)]
            .map { abs(Double($0)) }
            .max() ?? 0
        return min(1, peak)
    }
}

func activeTranscriptSegment(
    at time: Double,
    in segments: [TranscriptSegment],
    sync: PlaybackSync = PlaybackSync(systemOffset: 0)
) -> Int? {
    segments.enumerated()
        .filter { _, seg in time >= sync.displayStart(for: seg) && time <= sync.displayEnd(for: seg) }
        .max { lhs, rhs in sync.displayStart(for: lhs.element) < sync.displayStart(for: rhs.element) }?
        .offset
}

@MainActor
final class MeetingWaveformPlayer: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var activeSegmentIndex: Int?
    @Published private(set) var hasAudio = false
    @Published private(set) var waveforms: [MeetingWaveform] = []
    @Published private(set) var playbackSync = PlaybackSync(systemOffset: 0)

    private var micPlayer: AVAudioPlayer?
    private var systemPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var waveformTask: Task<Void, Never>?
    private var segments: [TranscriptSegment] = []
    private var loadedDirectory: URL?

    deinit {
        timer?.invalidate()
        waveformTask?.cancel()
    }

    func load(directory: URL, segments: [TranscriptSegment]) {
        self.segments = segments
        activeSegmentIndex = activeTranscriptSegment(at: currentTime, in: segments,
                                                     sync: playbackSync)
        guard loadedDirectory != directory else { return }

        pause()
        waveformTask?.cancel()
        loadedDirectory = directory
        currentTime = 0
        activeSegmentIndex = activeTranscriptSegment(at: 0, in: segments)

        guard let sources = meetingPlaybackSources(in: directory) else {
            micPlayer = nil
            systemPlayer = nil
            playbackSync = PlaybackSync(systemOffset: 0)
            duration = 0
            hasAudio = false
            waveforms = []
            return
        }

        micPlayer = sources.mic.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        systemPlayer = sources.system.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        [micPlayer, systemPlayer].compactMap { $0 }.forEach { $0.prepareToPlay() }
        playbackSync = PlaybackSync(systemOffset: sources.systemOffset)
        activeSegmentIndex = activeTranscriptSegment(at: 0, in: segments, sync: playbackSync)
        let micDuration = micPlayer?.duration ?? 0
        let correctedSystemDuration = max(0, (systemPlayer?.duration ?? 0) - sources.systemOffset)
        duration = max(micDuration, correctedSystemDuration)
        hasAudio = micPlayer != nil || systemPlayer != nil
        waveforms = [
            MeetingWaveform(label: "Mic", color: .blue, buckets: [], duration: 0,
                            isAvailable: sources.mic != nil),
            MeetingWaveform(label: "System", color: .green, buckets: [], duration: 0,
                            isAvailable: sources.system != nil),
        ]
        waveformTask = Task { [weak self, sources, directory] in
            let analyzed = await Task.detached {
                [
                    analyzeWaveform(url: sources.mic, label: "Mic", color: .blue, bucketCount: 140),
                    analyzeWaveform(url: sources.system, label: "System", color: .green,
                                    bucketCount: 140, sourceOffset: sources.systemOffset),
                ]
            }.value
            guard let self, self.loadedDirectory == directory, !Task.isCancelled else { return }
            self.waveforms = analyzed
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard hasAudio else { return }
        AudioSlicePlayer.shared.stop()
        if currentTime >= duration {
            seek(to: 0)
        }
        applyTrackMix(at: currentTime)
        micPlayer.map { player in
            player.currentTime = playbackSync.sourceTime(for: .mic, displayTime: currentTime,
                                                         duration: player.duration)
            player.play()
        }
        systemPlayer.map { player in
            player.currentTime = playbackSync.sourceTime(for: .system, displayTime: currentTime,
                                                         duration: player.duration)
            player.play()
        }
        isPlaying = true
        startTimer()
    }

    func pause() {
        [micPlayer, systemPlayer].compactMap { $0 }.forEach { $0.pause() }
        isPlaying = false
        stopTimer()
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, duration))
        currentTime = clamped
        activeSegmentIndex = activeTranscriptSegment(at: clamped, in: segments, sync: playbackSync)
        applyTrackMix(at: clamped)
        micPlayer.map { player in
            player.currentTime = playbackSync.sourceTime(for: .mic, displayTime: clamped,
                                                 duration: player.duration)
        }
        systemPlayer.map { player in
            player.currentTime = playbackSync.sourceTime(for: .system, displayTime: clamped,
                                                 duration: player.duration)
        }
    }

    func seekToSegment(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        seek(to: playbackSync.displayStart(for: segments[index]))
    }

    func playSegment(_ index: Int) {
        seekToSegment(index)
        play()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        let sourceTime = micPlayer?.currentTime
            ?? systemPlayer.map { max(0, $0.currentTime - playbackSync.systemOffset) }
            ?? currentTime
        currentTime = min(sourceTime, duration)
        activeSegmentIndex = activeTranscriptSegment(at: currentTime, in: segments, sync: playbackSync)
        applyTrackMix(at: currentTime)
        if currentTime >= duration {
            pause()
        }
    }

    private func applyTrackMix(at time: Double) {
        let mix = playbackMix(at: time, in: segments, sync: playbackSync)
        micPlayer?.volume = systemPlayer == nil ? 1 : mix.micVolume
        systemPlayer?.volume = micPlayer == nil ? 1 : mix.systemVolume
    }
}

func waveformBucketStartFrames(
    totalFrames: Int,
    sampleRate: Double,
    sourceOffset: Double,
    bucketCount: Int
) -> [Int64] {
    guard totalFrames > 0, sampleRate > 0, bucketCount > 0 else { return [] }
    let offsetFrames = min(totalFrames, max(0, Int((sourceOffset * sampleRate).rounded())))
    let availableFrames = totalFrames - offsetFrames
    guard availableFrames > 0 else { return [] }
    let bucketFrames = max(1, availableFrames / bucketCount)
    return (0..<bucketCount).compactMap { bucket in
        let start = offsetFrames + bucket * bucketFrames
        return start < totalFrames ? Int64(start) : nil
    }
}

func analyzeWaveform(url: URL?, label: String, color: Color, bucketCount: Int,
                     sourceOffset: Double = 0) -> MeetingWaveform {
    guard let url,
          let file = try? AVAudioFile(forReading: url),
          file.length > 0,
          bucketCount > 0
    else {
        return MeetingWaveform(label: label, color: color, buckets: [], duration: 0,
                               isAvailable: false)
    }

    let totalFrames = Int(file.length)
    let starts = waveformBucketStartFrames(
        totalFrames: totalFrames,
        sampleRate: file.fileFormat.sampleRate,
        sourceOffset: sourceOffset,
        bucketCount: bucketCount
    )
    var buckets: [Double] = []
    buckets.reserveCapacity(bucketCount)

    for (index, start) in starts.enumerated() {
        guard start < file.length else { break }
        file.framePosition = start
        let remaining = Int(file.length - start)
        let nextStart = index + 1 < starts.count ? Int(starts[index + 1] - start) : remaining
        let frames = min(max(1, nextStart), remaining)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { continue }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
        } catch {
            continue
        }
        buckets.append(bufferPeak(buffer))
    }

    return MeetingWaveform(label: label, color: color, buckets: buckets,
                           duration: max(0, Double(file.length) / file.fileFormat.sampleRate
                                         - sourceOffset),
                           isAvailable: !buckets.isEmpty)
}

private func bufferPeak(_ buffer: AVAudioPCMBuffer) -> Double {
    guard let channels = buffer.floatChannelData else { return 0 }
    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    guard channelCount > 0, frameCount > 0 else { return 0 }
    var peak: Float = 0
    for channel in 0..<channelCount {
        let data = channels[channel]
        for frame in 0..<frameCount {
            peak = max(peak, abs(data[frame]))
        }
    }
    return min(1, Double(peak))
}

struct DualWaveformTransport: View {
    @ObservedObject var player: MeetingWaveformPlayer

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!player.hasAudio)
                .help(player.isPlaying ? "Pause recording" : "Play recording")

                Text(timeText(player.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)

                Slider(value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ), in: 0...max(player.duration, 0.1))
                .disabled(!player.hasAudio)

                Text(timeText(player.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }

            VStack(spacing: 4) {
                ForEach(Array(player.waveforms.enumerated()), id: \.offset) { _, waveform in
                    WaveformLaneView(
                        waveform: waveform,
                        progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                        onSeekFraction: { player.seek(to: $0 * player.duration) }
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct WaveformLaneView: View {
    let waveform: MeetingWaveform
    let progress: Double
    let onSeekFraction: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.35))
                WaveformBarsView(waveform: waveform)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: max(0, min(proxy.size.width - 2,
                                          proxy.size.width * progress)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = max(0, min(1, value.location.x / max(proxy.size.width, 1)))
                onSeekFraction(fraction)
            })
        }
        .frame(height: 34)
        .opacity(waveform.isAvailable ? 1 : 0.45)
        .accessibilityLabel(waveform.label)
    }
}

private struct WaveformBarsView: View {
    let waveform: MeetingWaveform

    var body: some View {
        GeometryReader { proxy in
            let count = max(waveform.buckets.count, 1)
            let width = max(1, (proxy.size.width - CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(waveform.buckets.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: width / 2)
                        .fill(waveform.color.opacity(0.85))
                        .frame(width: width, height: max(2, proxy.size.height * value))
                }
                if waveform.buckets.isEmpty {
                    Rectangle()
                        .fill(.clear)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

private func timeText(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}
