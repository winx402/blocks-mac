// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BlocksMacOSProbe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BlocksMacOSProbe", targets: ["BlocksMacOSProbe"])
    ],
    targets: [
        .executableTarget(
            name: "BlocksMacOSProbe",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
