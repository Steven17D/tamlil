// swift-tools-version: 6.0
// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "Tamlil",
    platforms: [
        // Core Audio process taps need 14.4+; we target current macOS only.
        .macOS("15.0")
    ],
    targets: [
        // Tiny Objective-C shim so Swift can catch the NSExceptions AVAudioEngine
        // raises (e.g. installTap "format mismatch") instead of crashing.
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport"
        ),
        .executableTarget(
            name: "Tamlil",
            dependencies: ["ObjCSupport"],
            path: "Sources/Tamlil",
            swiftSettings: [
                // Callback-heavy AppKit/CoreAudio code; Swift 6 strict
                // concurrency adds noise without value here.
                .swiftLanguageMode(.v5),
                // The build is warning-free; keep it that way. Any new warning
                // fails the build wherever this target compiles (swift build,
                // swift run --self-check, build.sh). .unsafeFlags would make the
                // package unconsumable as a library dependency, which is fine:
                // Tamlil ships as a source-first app, never as a library.
                .unsafeFlags(["-warnings-as-errors"])
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
