// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode is deliberate: Apple's own interfaces are `-language-mode 5`, and the
// port must match their isolation semantics rather than invent stricter ones.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SwiftUI",
    products: [
        // The ported framework. Module name is `SwiftUI` so applications write `import SwiftUI`.
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
        // The Android app: runtime (JNI + canvas backend) + the app's scenes, one .so.
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
            path: "Sources/SwiftUI",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "SwiftUIAndroid",
            dependencies: ["SwiftUI", "AndroidBridge"],
            path: "Sources/SwiftUIAndroid",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "DemoApp",
            dependencies: ["SwiftUI"],
            path: "Sources/DemoApp",
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "SwiftUITests",
            dependencies: ["SwiftUI"],
            path: "Tests/SwiftUITests",
            swiftSettings: swift5Mode
        ),
    ]
)
