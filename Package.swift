// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppMixer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AppMixer", targets: ["AppMixer"])
    ],
    targets: [
        .executableTarget(
            name: "AppMixer",
            path: "Sources/AppMixer",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
