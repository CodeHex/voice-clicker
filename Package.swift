// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceClicker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoiceClicker",
            dependencies: ["RelayProtocol"],
            path: "Sources/VoiceClicker",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        // The Wi-Fi relay's messages, key exchange and signatures, with no I/O.
        .target(name: "RelayProtocol", path: "Sources/RelayProtocol"),
        // `swift run relay-protocol-check` checks RelayProtocol.
        .executableTarget(
            name: "relay-protocol-check",
            dependencies: ["RelayProtocol"],
            path: "Sources/RelayProtocolCheck"
        ),
    ]
)
