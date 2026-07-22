// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// `Tamlil --preview-windows` (with TAMLIL_RECORDINGS_ROOT staged data) opens
/// the main views as real titled windows so `screencapture -l<windowid>` can
/// grab faithful pixels for README screenshots. Offscreen rendering
/// (ImageRenderer / cacheDisplay / layer.render / dataWithPDF) cannot draw
/// this view tree — AppKit-backed controls and vibrant labels get dropped.
@MainActor
enum ScreenshotRenderer {
    static func renderIfRequested() {
        guard CommandLine.arguments.contains("--preview-windows") else { return }

        let state = AppState.shared
        state.refreshMeetings()

        var windows: [NSWindow] = [
            show(MenuView(openSettings: {}).environmentObject(state),
                 title: "tamlil-menu", size: MenuView.panelSize, at: 0)
        ]
        let detail = CGSize(width: 380, height: 560)
        if let meeting = state.meetings.first(where: { $0.phase == .ready }) {
            windows.append(show(
                MeetingDetailView(meeting: meeting)
                    .environmentObject(state),
                title: "tamlil-transcript", size: detail, at: 1,
                titleBar: meeting.displayTitle))
        }
        if let meeting = state.meetings.first(where: { $0.pendingClarifications > 0 }) {
            windows.append(show(
                MeetingDetailView(meeting: meeting)
                    .environmentObject(state),
                title: "tamlil-review", size: detail, at: 2,
                titleBar: meeting.displayTitle))
        }
        NSApp.activate(ignoringOtherApps: true)
        // Keep the windows alive for the capture script; quit via pkill.
        withExtendedLifetime(windows) {
            RunLoop.main.run()
        }
    }

    /// `titleBar` shows a real, visible window title — used for the transcript
    /// and review windows so the meeting name reads at the top of the shot;
    /// otherwise the title stays hidden for a clean panel look.
    private static func show<V: View>(_ view: V, title: String, size: CGSize,
                                      at index: Int, titleBar: String? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 60 + CGFloat(index) * 400, y: 300),
                                size: size),
            styleMask: titleBar == nil ? [.titled, .fullSizeContentView] : [.titled],
            backing: .buffered, defer: false
        )
        window.title = titleBar ?? title
        window.titlebarAppearsTransparent = titleBar == nil
        window.titleVisibility = titleBar == nil ? .hidden : .visible
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        window.orderFrontRegardless()
        return window
    }
}
