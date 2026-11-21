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

// Property wrappers (`State`, `Binding`, `Environment`, …) are macros. Apple's own macro
// plugin ships with the
// iOS SDK toolchain, so the port uses Apple's implementation to expand them rather than
// reimplementing the attribute semantics.
let pluginHost = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins"
let pluginServer = (ProcessInfo.processInfo.environment["SWIFT_TOOLCHAIN"]
    ?? "")
    + "/usr/bin/swift-plugin-server"

var portSDKFlags: [String] = [
    "-enable-experimental-feature", "AnyAppleOSAvailability",
    // Apple's declarations expect the vendored Combine module (see Sources/Combine/README.md).
    "-I", packageDirectory + "/Sources/COpenCombineHelpers/cmodule",
]
if FileManager.default.fileExists(atPath: pluginHost) {
    portSDKFlags += ["-external-plugin-path", pluginHost + "#" + pluginServer]
}

// Port SDK shims are archived by build-port-sdk.sh into one stable file; linking it is what
// satisfies the symbols Apple's declarations reference (UIKit, CoreGraphics, Symbols, Combine, …).
// A fixed path matters: SwiftPM evaluates this manifest once and caches the result, so globbing
// for objects here would silently miss newly built ones.
let shimArchive = packageDirectory + "/build/port-sdk/libportshims.a"

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
// Apple's declarations now compile for Android (gate: 0 errors) and the adapters compile against
// them, but the app still needs the Port SDK shims' object code resolved at link before the ported
// path can ship. Until then it is opt-in:
//   SWIFTUI_PORT_GENERATED=1 swift build --product SwiftUIAndroidApp …
// Apple's declarations are the default: `import SwiftUI` in an Android app resolves to their
// retargeted interfaces plus this project's engine. Set SWIFTUI_PORT_GENERATED=0 to build the
// older engine-level demo instead (kept as a reference implementation of the engine alone).
let includeGeneratedPort = ProcessInfo.processInfo.environment["SWIFTUI_PORT_GENERATED"] != "0"
// The port ships two independent demos. Atlas is the default; the control gallery is selected at
// compile time so each demo is a standalone app with its own application id:
//   SWIFTUI_DEMO_GALLERY=1 scripts/build-apk.sh --demo gallery …   (or scripts/gallery.sh)
let demoGallery = ProcessInfo.processInfo.environment["SWIFTUI_DEMO_GALLERY"] == "1"
let portSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(portSDKFlags),
]

// Platform modules Apple ships as frameworks but Android does not have (UIKit, CoreGraphics,
// Symbols, …) are *package targets* in the ported build: compiled together, linked into the same
// library, no archive juggling. They are omitted entirely from the default build — on macOS they
// would shadow Apple's own modules of the same name and break the engine's unit tests.
let portShimTargets: [Target] = includeGeneratedPort ? [
        .target(
            name: "FoundationShims",
            dependencies: [],
            path: "port-shims/FoundationShims",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "ObjectiveC",
            dependencies: [],
            path: "port-shims/ObjectiveC",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "UIUtilities",
            dependencies: [],
            path: "port-shims/UIUtilities",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "CoreGraphics",
            dependencies: [],
            path: "port-shims/CoreGraphics",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "QuartzCore",
            dependencies: [],
            path: "port-shims/QuartzCore",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "UniformTypeIdentifiers",
            dependencies: [],
            path: "port-shims/UniformTypeIdentifiers",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "CoreText",
            dependencies: ["UniformTypeIdentifiers"],
            path: "port-shims/CoreText",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "CoreTransferable",
            dependencies: ["UniformTypeIdentifiers"],
            path: "port-shims/CoreTransferable",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "Accessibility",
            dependencies: [],
            path: "port-shims/Accessibility",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "Spatial",
            dependencies: [],
            path: "port-shims/Spatial",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "simd",
            dependencies: [],
            path: "port-shims/simd",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "Darwin",
            dependencies: [],
            path: "port-shims/Darwin",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "OSLog",
            dependencies: [],
            path: "port-shims/OSLog",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "os",
            dependencies: [],
            path: "port-shims/os",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "DataDetection",
            dependencies: [],
            path: "port-shims/DataDetection",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "CoreMedia",
            dependencies: [],
            path: "port-shims/CoreMedia",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "CoreData",
            dependencies: [],
            path: "port-shims/CoreData",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "UIKit",
            dependencies: ["ObjectiveC", "CoreGraphics", "QuartzCore", "UIUtilities", "FoundationShims"],
            path: "port-shims/UIKit",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "Symbols",
            dependencies: [],
            path: "port-shims/Symbols",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "DeveloperToolsSupport",
            dependencies: [],
            path: "port-shims/DeveloperToolsSupport",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "COpenCombineHelpers",
            path: "Sources/COpenCombineHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Combine",
            dependencies: ["COpenCombineHelpers"],
            path: "Sources/Combine",
            swiftSettings: swift5Mode
        ),
] : []

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
            dependencies: ["SwiftUICore"],
            path: "Sources/SwiftUIExport",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "SwiftUICore",
            dependencies: includeGeneratedPort ? ["Combine", "Symbols", "UIKit", "CoreGraphics",
                           "FoundationShims", "ObjectiveC", "QuartzCore", "CoreText",
                           "CoreTransferable", "Accessibility", "Spatial", "simd", "Darwin",
                           "OSLog", "os", "DataDetection", "CoreMedia", "CoreData",
                           "UniformTypeIdentifiers", "DeveloperToolsSupport", "UIUtilities"] : [],
            path: "Sources/SwiftUI",
            // `Adapters` binds Apple's declared types to the engine, so it only compiles when the
            // generated declarations are in the target. See docs/RENDERER.md.
            exclude: includeGeneratedPort ? [] : ["Generated", "Adapters"],
            swiftSettings: portSettings
        ),
        .target(
            name: "SwiftUIAndroid",
            dependencies: ["SwiftUICore", "AndroidBridge"],
            path: "Sources/SwiftUIAndroid",
            swiftSettings: swift5Mode
        ),
        .target(
            name: "DemoApp",
            dependencies: ["SwiftUI"],
            path: "Sources/DemoApp",
            // The SwiftUI-hosted scene only compiles against the generated declarations.
            // The engine-level Atlas scene and the SwiftUI Atlas app define overlapping model
            // types, and each only makes sense in one build mode.
            // Which demo the hosted scene shows is a compile-time choice (`SWIFTUI_DEMO_GALLERY=1`
            // → ControlGallery, else the Atlas app), so each demo ships as its own APK.
            exclude: includeGeneratedPort
                ? ["AtlasScene.swift", "DemoTheme.swift", "NodeBuilders.swift"]
                  + (demoGallery ? ["AtlasApp.swift"] : [])
                // Engine-only mode has no `SwiftUI` module at all, so both SwiftUI demos (which
                // import it) stay out of that build.
                : ["SwiftUIHostScene.swift", "AtlasApp.swift", "ControlGallery.swift"],
            swiftSettings: includeGeneratedPort
                ? swift5Mode + [.define("PORT_RENDERER")] + (demoGallery ? [.define("PORT_DEMO_GALLERY")] : [])
                : swift5Mode
        ),
        .testTarget(
            name: "SwiftUITests",
            dependencies: ["SwiftUICore"],
            path: "Tests/SwiftUITests",
            swiftSettings: swift5Mode
        ),
    ] + portShimTargets
)
