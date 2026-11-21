# Port status

Living document. Updated as the port converges. Numbers are measured, not estimated.

## Bottom line

**Apple's compiled SwiftUI cannot run on Android.** It is a Darwin Mach-O dylib bound to
UIKitCore, QuartzCore/CA::Render, Metal and CoreText. Anyone who claims to run it on Android is
either streaming frames from a Mac/simulator or has reimplemented the API.

What this repository does instead is a genuine port of the framework's *publishable* half:

1. Apple's own module interfaces (`SwiftUI`, `SwiftUICore`, `Symbols`, `Combine`) are retargeted
   and recompiled for `aarch64-unknown-linux-android`, so application code compiles against
   **Apple's exact declarations** — types, generics, availability, result builders, SPI.
2. `@inlinable` bodies (1,022 of them across the two interfaces) are Apple's real code and are
   preserved verbatim, so they execute natively on Android.
3. Everything the interfaces declare but do not implement is supplied by this project's engine,
   drawing through Android's native Skia `Canvas`.

## Measured progress

| Area | State | Evidence |
|---|---|---|
| OSS Swift 6.4.3 toolchain, official Swift SDK for Android, NDK r30 | working | `swift build --swift-sdk swift-6.4.3-RELEASE_android --triple aarch64-unknown-linux-android28` → ELF aarch64 |
| Apple interface retargeting (`build-port-sdk.sh`) | `SwiftUICore`, `SwiftUI`, `Symbols`, `Combine` retarget clean | `build/port-sdk/gen/**` |
| Fidelity probe (`scripts/port/probe.swift`, real SwiftUI source) | converging | `build/port-sdk/probe.log` |
| Platform shims (`UIKit`, `CoreGraphics`, …) | in progress | `port-shims/**` |
| C JNI bridge (`AndroidBridge.c`) | complete: 10 JNI entry points, 22 drawing primitives, cached paints/typefaces, exception-safe | compiles for arm64 + x86_64 with `-Wall -Wextra` |
| Java host (`MainActivity`, `SwiftUIHostView`) | complete: edge-to-edge, insets, gestures, back, config survival | APK validated with `apksigner`/`zipalign` |
| APK pipeline (`build-apk.sh`) | complete: aapt2 → javac → d8 → zip → zipalign → sign, bundles Swift runtime dylibs from `llvm-readelf` NEEDED | `build/SwiftUI-Android.apk` |
| Emulator harness (`emulator.sh`, `device-test.sh`) | complete: headless API 35 arm64, install→launch→screenshot→crash assertions | `build/screenshots/**` |
| Engine: display list, painter, frame loop | complete for the proof path | 8 host tests green (`swift test`) |
| Engine: view graph (`_makeView`/`_ViewInputs`/`_ViewOutputs`) + layout + state | next | — |

## What the interfaces actually expose (and why that matters)

Apple's interface is unusually generous: it declares the engine seam itself.

```swift
public protocol View {
  nonisolated static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs
  nonisolated static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs
  nonisolated static func _viewListCount(inputs: _ViewListCountInputs) -> Int?
  associatedtype Body: View
  @ContentBuilder @MainActor var body: Body { get }
}
```

`_GraphValue`, `_ViewInputs`, `_ViewOutputs`, `_ViewListInputs`, `_ViewListOutputs`,
`_ViewListCountInputs` are opaque in the interface (their storage is internal), which means the
port can define their real contents. That is the architecture the port implements: a value graph
per frame → node tree → propose/measure/place → `DisplayList` → Android canvas.

## Known semantic gaps (by construction, not by accident)

| Gap | Why |
|---|---|
| No ObjC interop | Android has no ObjC runtime; `@objc` attributes are stripped when retargeting. UIKit-facing API is declarative only. |
| No Metal / CoreAnimation | rendering goes through `android.graphics.Canvas` (Skia, hardware accelerated), not CA::Render. |
| No CoreText | text shaping uses Android's `Paint`/`Typeface` (HarfBuzz under the hood) through the bridge. |
| No UIKit | `UIView`/`UIColor`/`UIImage` are declaration-faithful shims; bridging an actual `UIView` into the tree is impossible on Android. |
| Foundation must be dynamic | the Android SDK ships Foundation as dylibs (~74 MB bundled), so APK size is dominated by the Swift/Foundation runtime, not the port. |

## Reproduce

```bash
./scripts/port/build-port-sdk.sh          # retarget Apple interfaces + fidelity probe
./scripts/dev.sh                          # cross-compile → APK → install → screenshot
swift test                                # host-side engine tests
```
