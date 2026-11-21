// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrinityBar",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "TrinityBar", targets: ["TrinityBar"])
    ],
    targets: [
        .executableTarget(
            name: "TrinityBar",
            path: "Sources/TrinityBar",
            resources: [
                .copy("Resources/AppIcon.icns")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
