// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// The bring-your-own Google OAuth client pair, serialized to the gitignored
/// google_client.local.json beside the Python package — the exact file
/// google_client._local_config() reads; keep the two-key shape in sync.
struct GoogleClientConfig: Equatable {
    var clientId: String
    var clientSecret: String

    /// Stable two-key JSON, quote/backslash-escaped by hand so the output is
    /// deterministic.
    func json() -> String {
        #"{"client_id": \#(Self.quoted(clientId)), "client_secret": \#(Self.quoted(clientSecret))}"#
    }

    static func parse(_ text: String) -> GoogleClientConfig? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dict = object as? [String: Any],
              let id = dict["client_id"] as? String,
              let secret = dict["client_secret"] as? String
        else { return nil }
        return GoogleClientConfig(clientId: id, clientSecret: secret)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}

/// Keychain conventions for the Soniox API key — must stay in sync with the
/// Python read side (`security find-generic-password -s tamlil-soniox -w`).
enum SonioxKeychain {
    static let service = "tamlil-soniox"
    static let account = "soniox"

    /// `security` arguments that upsert the key: -U updates the existing item
    /// instead of accreting duplicates.
    static func addArgs(key: String) -> [String] {
        ["add-generic-password", "-U", "-s", service, "-a", account, "-w", key]
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("repoPath") private var repoPath = ""
    @AppStorage(DockPresence.key) private var showInDock = false
    @State private var keychainKeyPresent = false
    @State private var googleConnected = false
    @State private var connectingGoogle = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var sonioxKeyInput = ""
    @State private var googleClientId = ""
    @State private var googleClientSecret = ""
    @State private var googleClientSaved = false
    @State private var notifyMeetingEvents = AppState.shared.notifyMeetingEvents
    @State private var remindParticipants = AppState.shared.remindInformParticipants
    @State private var audioRetention = AppState.shared.audioRetentionRaw
    @State private var audioRetentionDays = AppState.shared.audioRetentionDays

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            try LoginItem.setEnabled(on)
                        } catch {
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                Toggle("Keep Tamlil in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, on in DockPresence.apply(on) }
                Text("Tamlil lives in the menu bar. If a crowded menu bar hides "
                     + "its icon, keep it in the Dock — or just open Tamlil again "
                     + "from Spotlight to bring its window back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Required") {
                if keychainKeyPresent {
                    LabeledContent {
                        Button("Clear") { clearSonioxKey() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Soniox API key")
                            statusBadge(ok: true, help: "Stored in Keychain")
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("Soniox API key")
                            statusBadge(ok: false, help: "Not set — transcription needs it")
                            Spacer()
                            Button("Save") { saveSonioxKey() }
                                .disabled(trimmed(sonioxKeyInput).isEmpty)
                        }
                        SecureField("", text: $sonioxKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                LabeledContent("Microphone") {
                    if micNeedsGrant {
                        Button("Grant") {
                            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                        }
                    } else {
                        statusBadge(ok: true, help: "Microphone access granted")
                    }
                }
                LabeledContent("System audio") {
                    if systemAudioAuthorized {
                        statusBadge(ok: true, help: "System-audio recording granted")
                    } else {
                        Button("Open Settings") {
                            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                        }
                    }
                }
            }
            Section {
                if googleConnected {
                    LabeledContent("Account") {
                        HStack(spacing: 10) {
                            statusBadge(ok: true, help: "Signed in — calendar roster enabled")
                            Text("Connected").foregroundStyle(.secondary)
                            Button { connectGoogle() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).help("Reconnect")
                            Button { clearGoogleClient() } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Clear credentials and sign out")
                        }
                    }
                } else if connectingGoogle {
                    LabeledContent("Account") {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Connecting…").foregroundStyle(.secondary)
                        }
                    }
                } else if repoPath.isEmpty {
                    Text("Set your Tamlil repo (below) first — the OAuth client is "
                         + "stored in that checkout.")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                } else {
                    TextField("Client ID", text: $googleClientId)
                        .textFieldStyle(.roundedBorder)
                    TextField("Client secret", text: $googleClientSecret)
                        .textFieldStyle(.roundedBorder)
                    LabeledContent("Account") {
                        HStack(spacing: 8) {
                            Button("Save client") { saveGoogleClient() }
                                .disabled(trimmed(googleClientId).isEmpty
                                          || trimmed(googleClientSecret).isEmpty)
                            Button { connectGoogle() } label: {
                                Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                            }
                            .disabled(!googleClientSaved)
                        }
                    }
                }
            } header: {
                Text("Google Calendar — optional")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Adds meeting titles and attendees from your calendar — "
                         + "everything else works without it.")
                    Link("Google Calendar setup guide",
                         destination: URL(string: "https://github.com/Steven17D/tamlil/blob/main/docs/google-calendar-setup.md")!)
                }
                .font(.caption)
            }
            Section("Notifications") {
                Toggle("Meeting notifications", isOn: $notifyMeetingEvents)
                    .onChange(of: notifyMeetingEvents) { _, v in state.notifyMeetingEvents = v }
                Text("Recording started, transcript ready, and unanswered-call notices. "
                     + "Problems such as a failed recording always notify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Remind me to inform participants when recording starts",
                       isOn: $remindParticipants)
                    .onChange(of: remindParticipants) { _, v in state.remindInformParticipants = v }
                    .disabled(!notifyMeetingEvents)
            }
            Section("Privacy & data handling") {
                Text("Audio — your microphone and the meeting's system audio — is "
                     + "uploaded to Soniox (US) for transcription. When Google Calendar "
                     + "is connected, meeting titles and attendees are read too. Tamlil "
                     + "sends no telemetry or analytics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Deletion: local files move to the Trash; the Soniox copy is "
                     + "auto-deleted after each run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Audio retention", selection: $audioRetention) {
                    Text("Keep").tag(RetentionPolicy.keep.rawValue)
                    Text("Delete after a number of days").tag(RetentionPolicy.deleteAfterDays.rawValue)
                    Text("Delete when transcript is final").tag(RetentionPolicy.deleteWhenFinal.rawValue)
                }
                .onChange(of: audioRetention) { _, v in state.audioRetentionRaw = v }
                if audioRetention == RetentionPolicy.deleteAfterDays.rawValue {
                    Stepper("Delete audio after \(audioRetentionDays) days",
                            value: $audioRetentionDays, in: 1...365)
                        .onChange(of: audioRetentionDays) { _, v in state.audioRetentionDays = v }
                }
                if audioRetention != RetentionPolicy.keep.rawValue {
                    Text("Deleting audio disables playback and the audio replay on "
                         + "clarification cards for that recording.")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
                Link("Data-handling details",
                     destination: URL(string: "https://github.com/Steven17D/tamlil/blob/main/docs/soniox-data-processing.md")!)
                    .font(.caption)
            }
            Section("Pipeline") {
                HStack {
                    TextField("path to your tamlil checkout", text: $repoPath)
                    Button {
                        pickRepoFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose the tamlil repo folder")
                }
                if repoPath.isEmpty {
                    LabeledContent("Repo") {
                        Text("Set your Tamlil repo: point this at your git checkout "
                             + "(the folder that holds src/tamlil). The pipeline, "
                             + "calendar sign-in, and updater all run from there.")
                            .foregroundStyle(.secondary)
                    }
                } else if !repoPathValid {
                    LabeledContent("Repo check") {
                        Text("no tamlil package here — pick the folder that holds "
                             + "src/tamlil/meeting_pipeline.py")
                            .foregroundStyle(Color.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear {
            keychainKeyPresent = Self.keychainPresent(service: SonioxKeychain.service)
            googleConnected = Self.keychainPresent(service: "tamlil-google")
            reloadGoogleClient()
        }
        .onChange(of: repoPath) { _, _ in reloadGoogleClient() }
    }

    /// The gitignored client file the Python side reads
    /// (google_client._local_config()); nil until the repo path is set.
    private var googleClientURL: URL? {
        guard !repoPath.isEmpty else { return nil }
        return URL(fileURLWithPath: repoPath, isDirectory: true)
            .appendingPathComponent("src/tamlil/google_client.local.json")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A green check / red warning badge with the detail on hover, so status
    /// fits on one line instead of a caption row.
    private func statusBadge(ok: Bool, help: String) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.red)
            .help(help)
    }

    /// Show "Grant" only on a definitive denial. This app captures the mic through
    /// AVAudioEngine, which can leave the AVCapture status at .notDetermined even
    /// while recording works, so anything but .denied/.restricted counts as fine.
    private var micNeedsGrant: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private var systemAudioAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    private func saveSonioxKey() {
        let key = trimmed(sonioxKeyInput)
        guard !key.isEmpty else { return }
        Self.runSecurity(SonioxKeychain.addArgs(key: key))
        sonioxKeyInput = ""
        keychainKeyPresent = Self.keychainPresent(service: SonioxKeychain.service)
    }

    private func clearSonioxKey() {
        Self.runSecurity(["delete-generic-password", "-s", SonioxKeychain.service])
        keychainKeyPresent = Self.keychainPresent(service: SonioxKeychain.service)
    }

    /// Remove the stored OAuth client and per-user token, returning the section
    /// to the "enter client id/secret" state.
    private func clearGoogleClient() {
        if let url = googleClientURL { try? FileManager.default.removeItem(at: url) }
        Self.runSecurity(["delete-generic-password", "-s", "tamlil-google"])
        googleClientId = ""
        googleClientSecret = ""
        googleClientSaved = false
        googleConnected = false
    }

    private func saveGoogleClient() {
        guard let url = googleClientURL else { return }
        googleClientId = trimmed(googleClientId)
        googleClientSecret = trimmed(googleClientSecret)
        let cfg = GoogleClientConfig(clientId: googleClientId,
                                     clientSecret: googleClientSecret)
        do {
            try (cfg.json() + "\n").write(to: url, atomically: true, encoding: .utf8)
            googleClientSaved = true
        } catch {
            state.lastError = "Could not write google_client.local.json: "
                + error.localizedDescription
        }
    }

    /// Prefill from the local JSON; never clobbers typed-in values when the
    /// file is absent or unreadable.
    private func reloadGoogleClient() {
        guard let url = googleClientURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let cfg = GoogleClientConfig.parse(text)
        else {
            googleClientSaved = false
            return
        }
        googleClientId = cfg.clientId
        googleClientSecret = cfg.clientSecret
        googleClientSaved = !(cfg.clientId.isEmpty || cfg.clientSecret.isEmpty)
    }

    /// Re-checked on every keystroke in the path field; a stat is cheap.
    private var repoPathValid: Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue
        else { return false }
        return fm.fileExists(
            atPath: (repoPath as NSString).appendingPathComponent("src/tamlil/meeting_pipeline.py")
        )
    }

    private func pickRepoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = repoPath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
            : URL(fileURLWithPath: repoPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
        }
    }

    private func openSettings(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// Spawn `uv run tamlil-auth` in the resolved repo; it opens the browser for
    /// Google consent. Refresh the row when it returns. Best-effort — the install
    /// path also covers first-run consent.
    private func connectGoogle() {
        guard let repo = PipelineRunner.resolvedRepo() else {
            state.lastError = "Set your Tamlil repo in Settings before connecting Google."
            return
        }
        connectingGoogle = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "exec uv run tamlil-auth"]
        task.currentDirectoryURL = repo
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                connectingGoogle = false
                googleConnected = Self.keychainPresent(service: "tamlil-google")
            }
        }
        do { try task.run() } catch { connectingGoogle = false }
    }

    /// Spawns /usr/bin/security — run once on appear, not per render.
    static func keychainPresent(service: String) -> Bool {
        runSecurity(["find-generic-password", "-s", service])
    }

    /// Run /usr/bin/security to completion, discarding its output.
    @discardableResult
    private static func runSecurity(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

}
