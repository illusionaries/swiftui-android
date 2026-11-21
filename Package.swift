// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftUI",
    products: [
        // The SwiftUI-compatible framework (portable, no platform calls).
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
        // The Android app: SwiftUIAndroid runtime + the demo app, linked into one .so.
        .library(name: "SwiftUIAndroidApp", type: .dynamic, targets: ["SwiftUIAndroid", "DemoApp"]),
    ],
    targets: [
        .target(
            name: "AndroidBridge",
            path: "Sources/AndroidBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SwiftUI",
            path: "Sources/SwiftUI"
        ),
        .target(
            name: "SwiftUIAndroid",
            dependencies: ["SwiftUI", "AndroidBridge"],
            path: "Sources/SwiftUIAndroid"
        ),
        .target(
            name: "DemoApp",
            dependencies: ["SwiftUI"],
            path: "Sources/DemoApp"
        ),
        .testTarget(
            name: "SwiftUITests",
            dependencies: ["SwiftUI"],
            path: "Tests/SwiftUITests"
        ),
    ]
)
