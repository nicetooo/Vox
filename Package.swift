// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceAssistant",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "VoiceAssistant",
            dependencies: ["CSQLite"],
            path: "Sources/VoiceAssistant",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("NaturalLanguage"),
            ]
        )
    ]
)
