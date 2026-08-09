// swift-tools-version: 6.2
// Viewport version: 0.1.0 (CFBundleShortVersionString in the app Info.plist)

import PackageDescription

let package = Package(
    name: "Viewport",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Viewport", targets: ["Viewport"])
    ],
    targets: [
        .target(
            name: "IndigoTouch",
            path: "Sources/IndigoTouch",
            sources: ["ViewportIndigoTouch.m"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath(".")
            ],
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "Viewport",
            dependencies: ["IndigoTouch"],
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
