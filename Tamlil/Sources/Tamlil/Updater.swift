// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Pull-based self-update. Runs scripts/update.sh from the resolved repo in a
/// detached login shell: it pulls the latest snapshot, rebuilds, reinstalls to
/// /Applications, and relaunches. Detached (and not named "Tamlil") so it
/// survives the `pkill` that swaps the running app out.
enum Updater {
    @MainActor
    static func checkForUpdates() {
        guard let repo = PipelineRunner.resolvedRepo() else {
            AppState.shared.lastError = "Set your Tamlil repo in Settings before checking for updates."
            return
        }
        let script = repo.appendingPathComponent("scripts/update.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            AppState.shared.lastError = "scripts/update.sh not found in \(repo.path)"
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell so git/uv/swift from the user's environment resolve.
        task.arguments = ["-lc", "exec scripts/update.sh"]
        task.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["TAMLIL_DIR"] = repo.path
        task.environment = env
        do {
            try task.run()
            Notifier.notify(title: "Tamlil", body: "Checking for updates…")
        } catch {
            AppState.shared.lastError = "update failed to start: \(error.localizedDescription)"
        }
    }
}
