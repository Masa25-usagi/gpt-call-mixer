// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MeetVoiceBridge",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "MeetVoiceBridge", targets: ["MeetVoiceBridge"])
    ],
    targets: [
        .executableTarget(
            name: "MeetVoiceBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
