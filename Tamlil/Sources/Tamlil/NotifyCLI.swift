// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UserNotifications

/// `Tamlil --notify "message"` posts one notification attributed to Tamlil and
/// exits. Used by scripts/update.sh (which runs detached, outside the app) so
/// update notices come from Tamlil — a tap activates the app — instead of
/// `osascript`, whose notifications are owned by Script Editor and open it on tap.
enum NotifyCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--notify"), flag + 1 < args.count else { return }
        let content = UNMutableNotificationContent()
        content.title = "Tamlil"
        content.body = args[flag + 1]
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { _ in done.signal() }
        // The add is async; wait briefly so the notification is handed to the
        // system before this short-lived process exits.
        _ = done.wait(timeout: .now() + 3)
        exit(0)
    }
}
