// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlowLocal",
    platforms: [.macOS("13.3")],   // официальный xcframework собран под 13.3+
    targets: [
        // Готовый XCFramework whisper.cpp (Metal включён, metallib встроен).
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip",
            checksum: "1c7a93bd20fe4e57e0af12051ddb34b7a434dfc9acc02c8313393150b6d1821f"
        ),
        .executableTarget(
            name: "FlowLocal",
            dependencies: ["whisper"],
            path: "Sources/FlowLocal",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
