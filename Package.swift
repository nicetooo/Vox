// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Znote",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "Znote",
            dependencies: [
                "CSQLite",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Znote",
            // sign.sh assembles the .app bundle manually (Info.plist, .icns,
            // entitlements, and the en/zh-Hans .lproj folders), so SwiftPM
            // doesn't need to know about them. Excluding keeps SwiftPM from
            // complaining about "unhandled resources" or insisting on a
            // defaultLocalization for resources we ship outside of SwiftPM.
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("NaturalLanguage"),
            ]
        )
    ]
)
