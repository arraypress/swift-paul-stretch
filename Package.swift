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
        .library(name: "PaulStretchSession", targets: ["PaulStretchSession"]),
    ],
    targets: [
        .target(name: "PaulStretch"),
        .target(name: "PaulStretchEffects", dependencies: ["PaulStretch"]),
        .target(name: "PaulStretchSession", dependencies: ["PaulStretch", "PaulStretchEffects"]),
        .testTarget(name: "PaulStretchTests", dependencies: ["PaulStretch"]),
        .testTarget(name: "PaulStretchEffectsTests", dependencies: ["PaulStretchEffects"]),
        .testTarget(name: "PaulStretchSessionTests", dependencies: ["PaulStretchSession"]),
    ]
)
