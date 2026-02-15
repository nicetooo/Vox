// swift-tools-version: 5.9
import PackageDescription

let package = Package(
            name: "Vox",
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
    name: "Vox",
            dependencies: ["CSQLite"],
            path: "Sources/Vox",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("NaturalLanguage"),
            ]
        )
    ]
)
