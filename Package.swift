// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Viewport",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Viewport", targets: ["Viewport"])
    ],
    targets: [
        .executableTarget(
            name: "Viewport",
            path: "Sources/Viewport",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ViewportTests",
            dependencies: ["Viewport"],
            path: "Tests/ViewportTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
