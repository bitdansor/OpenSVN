// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenSVN",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenSVNCore", targets: ["OpenSVNCore"]),
        .executable(name: "OpenSVN", targets: ["OpenSVN"]),
        // Development-only: lets the shell scenarios assert the app's error
        // classification. Not part of the app bundle.
        .executable(name: "opensvn-probe", targets: ["OpenSVNProbe"])
    ],
    targets: [
        .target(
            name: "OpenSVNCore",
            path: "Sources/OpenSVNCore"
        ),
        .executableTarget(
            name: "OpenSVN",
            dependencies: ["OpenSVNCore"],
            path: "Sources/OpenSVN"
        ),
        .executableTarget(
            name: "OpenSVNProbe",
            dependencies: ["OpenSVNCore"],
            path: "Sources/OpenSVNProbe"
        ),
        .testTarget(
            name: "OpenSVNCoreTests",
            dependencies: ["OpenSVNCore"],
            path: "Tests/OpenSVNCoreTests"
        )
    ]
)
