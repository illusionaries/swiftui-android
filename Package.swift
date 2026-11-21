// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode is deliberate: Apple's own interfaces are `-language-mode 5`, and the
// port must match their isolation semantics rather than invent stricter ones.
//
// The `SwiftUI` target compiles Apple's retargeted declarations (Sources/SwiftUI/Generated)
// plus the port's engine (Sources/SwiftUI/Engine). Those declarations `import Combine`,
// `Symbols`, and the platform shims, which come from the Port SDK that
// scripts/port/build-port-sdk.sh produces. `-I` is how a foreign module is consumed.
// Absolute paths: SwiftPM does not run the compiler with the package directory as cwd, so
// relative `-I` flags silently point at the wrong tree (this cost us a "no such module
// 'Combine'" that looked like a missing interface).
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
// `deps/` holds every Port SDK module *except* SwiftUI/SwiftUICore. Those two must not be on the
// path: the target below is itself named SwiftUI and already contains SwiftUICore's
// declarations, so exposing the prebuilt interface modules makes every type ambiguous.
let depsPath = packageDirectory + "/build/port-sdk/deps"
let portModulesPath = FileManager.default.fileExists(atPath: depsPath)
    ? depsPath
    : packageDirectory + "/build/port-sdk/gen"
let portSDKFlags: [String] = [
    "-I", portModulesPath,
    "-I", packageDirectory + "/build/port-sdk/shims",
    "-enable-experimental-feature", "AnyAppleOSAvailability",
]

let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// Apple's declarations (Sources/SwiftUI/Generated) are still being brought up against the
// platform shims: the interface recompiles, but `UIKit` and a handful of Darwin-only types are
// not yet satisfied on Android. They are therefore opt-in, so the repository always has a
// building product. Validate the generated port with:
//
//   SWIFTUI_PORT_GENERATED=1 swift build --product SwiftUIAndroidApp \
//       --swift-sdk swift-6.4.3-RELEASE_android --triple aarch64-unknown-linux-android28
//
// Once the Port SDK probe is green (scripts/port/build-port-sdk.sh), flip the default below to
// `true` — the engine and its adapters are written against those declarations.
let includeGeneratedPort = ProcessInfo.processInfo.environment["SWIFTUI_PORT_GENERATED"] == "1"
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
            exclude: includeGeneratedPort ? [] : ["Generated"],
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
