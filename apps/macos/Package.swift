// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenSVN",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenSVNCore", targets: ["OpenSVNCore"]),
        .executable(name: "OpenSVN", targets: ["OpenSVN"])
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
        .testTarget(
            name: "OpenSVNCoreTests",
            dependencies: ["OpenSVNCore"],
            path: "Tests/OpenSVNCoreTests"
        )
    ]
)
