// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlocksSchemaValidatorProbe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BlocksSchemaValidatorProbe", targets: ["BlocksSchemaValidatorProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.13.1")
    ],
    targets: [
        .target(name: "BlocksSchemaValidatorProbe", exclude: ["README.md"]),
        .testTarget(
            name: "BlocksSchemaValidatorProbeTests",
            dependencies: [
                "BlocksSchemaValidatorProbe",
                .product(name: "JSONSchema", package: "swift-json-schema")
            ]
        )
    ]
)
