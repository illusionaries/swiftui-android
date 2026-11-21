// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode is deliberate: Apple's own interfaces are `-language-mode 5`, and the
// port must match their isolation semantics rather than invent stricter ones.
//
// The `SwiftUI` target compiles Apple's retargeted declarations (Sources/SwiftUI/Generated)
// plus the port's engine (Sources/SwiftUI/Engine). Those declarations `import Combine`,
// `Symbols`, and the platform shims, which come from the Port SDK that
// scripts/port/build-port-sdk.sh produces. `-I` is how a foreign module is consumed.
let portSDKFlags: [String] = [
    "-I", "build/port-sdk/gen",
    "-I", "build/port-sdk/shims",
    "-enable-experimental-feature", "AnyAppleOSAvailability",
]

let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let portSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(portSDKFlags),
]

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
            swiftSettings: portSettings
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
