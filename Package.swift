// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaulStretch",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "PaulStretch", targets: ["PaulStretch"]),
        .library(name: "PaulStretchEffects", targets: ["PaulStretchEffects"]),
    ],
    targets: [
        .target(name: "PaulStretch"),
        .target(name: "PaulStretchEffects", dependencies: ["PaulStretch"]),
        .testTarget(name: "PaulStretchTests", dependencies: ["PaulStretch"]),
        .testTarget(name: "PaulStretchEffectsTests", dependencies: ["PaulStretchEffects"]),
    ]
)
