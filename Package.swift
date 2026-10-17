// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Onword",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Onword", targets: ["Onword"]),
    ],
    dependencies: [
        // On-device Whisper (Core ML). Pinned to a release that is at least two weeks old.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        // Pure logic with no system dependencies, so it can be unit tested.
        .target(name: "OnwordCore"),
        .executableTarget(
            name: "Onword",
            dependencies: [
                "OnwordCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                // On-device speaker diarization (Pyannote on Core ML) for meeting transcripts.
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(name: "OnwordCoreTests", dependencies: ["OnwordCore"]),
        .testTarget(name: "OnwordTests", dependencies: ["Onword"]),
    ]
)
