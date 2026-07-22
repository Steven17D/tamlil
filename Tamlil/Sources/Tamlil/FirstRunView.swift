// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

/// Labels for permissions that still need the user's attention. Pure so the
/// self-check can cover it; the view maps live TCC statuses into the two flags.
func permissionsNeedingAttention(micDenied: Bool, notificationsDenied: Bool) -> [String] {
    var out: [String] = []
    if micDenied { out.append("Microphone") }
    if notificationsDenied { out.append("Notifications") }
    return out
}

/// First-launch panel: states plainly what leaves the machine, then primes the
/// microphone and notification permissions so the first recording isn't a
/// silent failure. System-audio TCC has no status API, so it stays a link.
struct FirstRunView: View {
    let openSettings: () -> Void
    let onDone: () -> Void
    @State private var micGranted = false
    @State private var notificationsGranted = false

    private var pendingPermissions: [String] {
        permissionsNeedingAttention(micDenied: !micGranted, notificationsDenied: !notificationsGranted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Tamlil").font(.title2.bold())
            Text("Tamlil lives in the menu bar. It records your Zoom and Slack calls "
                 + "automatically and transcribes them.")
                .foregroundStyle(.secondary)

            GroupBox("What leaves your machine") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio — your microphone and the meeting's system audio — is "
                         + "uploaded to Soniox (US) for transcription. When you connect "
                         + "Google Calendar, meeting titles and attendees are read too. "
                         + "Tamlil sends no telemetry or analytics.")
                    Text("On delete, local files move to the Trash; the Soniox copy is "
                         + "auto-deleted after each run.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions").font(.headline)
                permissionRow(label: "Microphone", granted: micGranted,
                              action: "Grant") { requestMic() }
                permissionRow(label: "Notifications", granted: notificationsGranted,
                              action: "Enable") { requestNotifications() }
                HStack {
                    Label("System audio", systemImage: "speaker.wave.2")
                    Spacer()
                    Button("Open System Settings") { openSystemAudioSettings() }
                }
                Text("Grant system-audio recording under Privacy & Security ▸ "
                     + "Screen & System Audio Recording.")
                    .font(.caption).foregroundStyle(.secondary)
                if !pendingPermissions.isEmpty {
                    Text("Still needed: \(pendingPermissions.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            HStack {
                Button("Set your Soniox key…") { openSettings() }
                Spacer()
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: refreshStatuses)
    }

    private func permissionRow(label: String, granted: Bool, action: String,
                               act: @escaping () -> Void) -> some View {
        HStack {
            Label(label, systemImage: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.primary)
            Spacer()
            if !granted { Button(action, action: act) }
        }
    }

    private func refreshStatuses() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized
            DispatchQueue.main.async { notificationsGranted = ok }
        }
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { notificationsGranted = granted }
        }
    }

    private func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
