// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import os
import UserNotifications

enum Log {
    static let app = Logger(subsystem: "dev.dashevsky.tamlil", category: "app")
}

private let kOpenFolderAction = "OPEN_FOLDER"
private let kShowTranscriptAction = "SHOW_TRANSCRIPT"
private let kMeetingCategory = "MEETING"
private let notificationResponder = NotificationResponder()

@MainActor
enum Notifier {
    /// Register the response delegate and the meeting category (its "Open folder"
    /// action). Call once at launch, after requestPermission().
    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationResponder
        let showTranscript = UNNotificationAction(
            identifier: kShowTranscriptAction, title: "Show transcript", options: [.foreground])
        let openFolder = UNNotificationAction(
            identifier: kOpenFolderAction, title: "Open folder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: kMeetingCategory,
                                   actions: [showTranscript, openFolder],
                                   intentIdentifiers: [], options: []),
        ])
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a notification. `threadIdentifier` groups a recording's notifications
    /// together; `folderPath` adds the "Open folder" action and makes a tap open
    /// the recording; `sound` is used for problems so a failure is audible.
    static func notify(title: String, body: String,
                       threadIdentifier: String? = nil,
                       folderPath: String? = nil,
                       sound: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let threadIdentifier { content.threadIdentifier = threadIdentifier }
        if let folderPath {
            content.userInfo = ["folderPath": folderPath]
            content.categoryIdentifier = kMeetingCategory
        }
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Handles notification taps: "Show transcript" opens the meeting in the main
/// window, "Open folder" reveals the recording directory, and a plain tap
/// brings Tamlil forward.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["folderPath"] as? String
        switch response.actionIdentifier {
        case kOpenFolderAction:
            if let path {
                await MainActor.run {
                    _ = NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
                }
            }
        case kShowTranscriptAction:
            if let path {
                let id = RecordingID(URL(fileURLWithPath: path).lastPathComponent)
                await MainActor.run { AppState.shared.openMeeting(id) }
            }
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run { NSApplication.shared.activate() }
        default:
            break
        }
    }
}
