// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var state: AppState
    /// Injected by the owner: the popover hosts this view outside the SwiftUI
    /// scene graph, so `@Environment(\.openSettings)` isn't wired here.
    let openSettings: () -> Void
    /// Only the standalone main window consumes `AppState.meetingToOpen` (a
    /// notification's "Show transcript" action); the popover ignores it.
    var respondsToOpenRequests = false
    @State private var navPath: [RecordingID] = []
    @State private var errorShown = false
    @State private var trashTarget: Meeting?
    @State private var renameTarget: Meeting?
    @State private var renameText = ""
    // Live updates while the pipeline runs in the background.
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(alignment: .leading, spacing: 0) {
                statusHeader
                if MicRecorder.permissionDenied {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.slash").foregroundStyle(.orange)
                        Text("Microphone access is off — recordings won't include your voice.")
                            .font(.caption)
                        Spacer()
                        Button("Fix") { openSettings() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12))
                }
                Divider()
                meetingList
                Divider()
                footer
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .onAppear {
            state.refreshMeetings()
            consumeOpenRequest()
        }
        .onReceive(refresh) { _ in
            if state.shouldAutoRefresh { state.refreshMeetings() }
        }
        .onChange(of: state.meetingToOpen) { _, _ in consumeOpenRequest() }
    }

    /// Navigate the main window to a meeting a notification action requested,
    /// then clear the request so it can't re-fire. A no-op in the popover.
    private func consumeOpenRequest() {
        guard respondsToOpenRequests, let id = state.meetingToOpen else { return }
        navPath = [id]
        state.meetingToOpen = nil
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            switch state.status {
            case .recording(let app, let since):
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording \(app) call").font(.headline)
                    Text(since, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { state.endRecording() }
            case .idle:
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for a call").font(.headline)
                    Text(state.autoRecord
                         ? "Auto-records Zoom & Slack huddles"
                         : "Auto-record is off")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $state.autoRecord)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .padding(12)
    }

    private var meetingList: some View {
        Group {
            if state.meetings.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("No meetings yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Join a Zoom call or Slack huddle —\nTamlil records and transcribes automatically.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(state.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        MeetingRow(meeting: meeting)
                            .contextMenu {
                                if isDeletable(meeting) {
                                    Button("Rename…") {
                                        renameText = meeting.meta.eventTitle ?? ""
                                        renameTarget = meeting
                                    }
                                    Button("Move to Trash", role: .destructive) {
                                        trashTarget = meeting
                                    }
                                } else {
                                    Text("Stop recording / wait for processing to delete")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .navigationDestination(for: RecordingID.self) { id in
                    if let meeting = state.meetings.first(where: { $0.id == id }) {
                        MeetingDetailView(meeting: meeting, showsBackButton: true)
                    }
                }
                .confirmationDialog(
                    "Move this meeting to the Trash?",
                    isPresented: Binding(
                        get: { trashTarget != nil },
                        set: { if !$0 { trashTarget = nil } }
                    ),
                    presenting: trashTarget
                ) { meeting in
                    Button("Move to Trash", role: .destructive) { trash(meeting) }
                } message: { meeting in
                    Text(meeting.directory.lastPathComponent)
                }
                .alert(
                    "Rename meeting",
                    isPresented: Binding(
                        get: { renameTarget != nil },
                        set: { if !$0 { renameTarget = nil } }
                    ),
                    presenting: renameTarget
                ) { meeting in
                    TextField(meeting.autoTitle, text: $renameText)
                    Button("Save") { rename(meeting, to: renameText) }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("Leave empty to use the automatic title.")
                }
            }
        }
    }

    /// Never delete the live recording's directory or one a pipeline is actively
    /// writing — that would truncate the wav mid-capture or corrupt outputs.
    private func isDeletable(_ meeting: Meeting) -> Bool {
        meeting.directory != state.recordingDir && !state.isPipelineRunning(meeting)
    }

    /// Move the recording's folder to the Trash, then drop its DB row so the
    /// meeting leaves the list for good. The row (not the folder) is the list's
    /// source of truth, so deleting it is what actually removes the meeting;
    /// the folder is only ever trashed, never permanently deleted. A folder
    /// that's already gone (a phantom row from an earlier partial trash) is
    /// treated as success so it can finally be cleared.
    private func trash(_ meeting: Meeting) {
        guard isDeletable(meeting) else {
            state.lastError = "can't delete a recording in progress"
            return
        }
        let appState = state
        let id = meeting.id
        let directory = meeting.directory
        Task.detached {
            let fm = FileManager.default
            var failure: String?
            if fm.fileExists(atPath: directory.path) {
                do {
                    try fm.trashItem(at: directory, resultingItemURL: nil)
                } catch {
                    failure = "couldn't move to Trash: \(error.localizedDescription)"
                }
            }
            // Cross the actor boundary with a Sendable String, not the Error.
            let message = failure
            await MainActor.run {
                if let message {
                    appState.lastError = message
                } else {
                    MeetingStore.delete(id)
                }
                appState.refreshMeetings()
            }
        }
    }

    private func rename(_ meeting: Meeting, to title: String) {
        MeetingStore.rename(meeting.id, to: title)
        state.refreshMeetings()
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(MeetingStore.root)
            } label: {
                Label("Recordings", systemImage: "folder")
            }
            Spacer()
            if let err = state.lastError {
                Button {
                    errorShown.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .help("Show last error")
                .popover(isPresented: $errorShown, arrowEdge: .top) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(err)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            state.lastError = nil
                            errorShown = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                    }
                    .padding(10)
                }
            }
            Button {
                Updater.checkForUpdates()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Check for updates")
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Tamlil")
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

extension MenuView {
    /// Canonical size of the menu panel, shared by the popover, the standalone
    /// window, and the screenshot renderer so they can't drift apart.
    static let panelSize = NSSize(width: 380, height: 460)

    /// The one place the panel is stood up for AppKit hosting (popover and
    /// window): identical dependency wiring and environment every time.
    @MainActor
    static func hostingController(openSettings: @escaping () -> Void,
                                  respondsToOpenRequests: Bool = false) -> NSViewController {
        NSHostingController(rootView: MenuView(openSettings: openSettings,
                                               respondsToOpenRequests: respondsToOpenRequests)
            .environmentObject(AppState.shared))
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            appBadge
            VStack(alignment: .leading, spacing: 2) {
                line(title, font: .body.weight(.medium), limit: 1)
                line(subtitle, font: .caption, color: .secondary, limit: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stateIcon
        }
        .padding(.vertical, 4)
    }

    /// One text line, bidi-corrected and right-aligned when it's Hebrew.
    @ViewBuilder private func line(
        _ text: String, font: Font, color: HierarchicalShapeStyle = .primary, limit: Int
    ) -> some View {
        let rtl = text.isRTL
        Text(rtl ? rtlEmbedded(text) : text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(limit)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }

    private var appBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(appColor.gradient)
                .frame(width: 28, height: 28)
            Image(systemName: appSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var appColor: Color {
        switch meeting.meta.app {
        case "Zoom": return Color(red: 0.18, green: 0.55, blue: 1.0)
        case "Slack": return Color(red: 0.29, green: 0.08, blue: 0.29)
        case "Teams": return Color(red: 0.38, green: 0.36, blue: 0.75)
        default: return .gray
        }
    }

    private var appSymbol: String {
        switch meeting.meta.app {
        case "Zoom": return "video.fill"
        case "Slack": return "headphones"
        case "Teams": return "person.2.fill"
        default: return "waveform"
        }
    }

    /// Custom title if the user set one, else the auto "<app> with <people>" /
    /// "<app> huddle" line.
    private var title: String { meeting.displayTitle }

    /// Date · duration · state. App is conveyed by the colored badge, not text.
    private var subtitle: String {
        var parts = [Meeting.displayDateFormatter.string(from: meeting.meta.startedAt)]
        if let d = meeting.durationText { parts.append(d) }
        if let stage = meeting.stageText {
            parts.append("\(meeting.displayState) — \(stage)")
        } else {
            parts.append(meeting.displayState)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var stateIcon: some View {
        switch meeting.phase {
        case .recording:
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .queued, .processing:
            ProgressView().controlSize(.small)
        case .needsClarification(let pending):
            Text("\(pending)?")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(.orange)
                .background(.orange.opacity(0.16), in: Capsule())
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .discarded, .unknown:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
