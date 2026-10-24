// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceClicker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoiceClicker",
            path: "Sources/VoiceClicker",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)
