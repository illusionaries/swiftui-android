# SwiftUI for Android — Architecture

## The constraint (read this first)

Apple's `SwiftUI` framework is **closed source**. There is no source tree to port, so a
literal "port" is impossible. What *is* official is:

* the official Swift toolchain (swift.org), and
* the official **Swift SDK for Android** (`swift sdk install`, swift.org, shipped since 2025).

So this project does the only faithful thing available: it **reimplements the SwiftUI
programming model in Swift** — the same API names, the same result builders, the same
property-wrapper state model, the same measure/place/paint layout discipline — compiled by
the official toolchain with the official Android SDK, and rendered through **Android's own
native renderer** (hardware-accelerated `android.graphics.Canvas`, i.e. real Skia, real
system fonts, real touch pipeline) over JNI.

What this is **not**:

* not a transpiler to Jetpack Compose (no Compose runtime, no Kotlin UI, no code generation)
* not a web view / Flutter-style embed
* not a Kotlin reimplementation

SwiftUI code written against this module compiles *as Swift* for Android and draws through
the platform's native canvas stack — the same layer UIKit/CoreGraphics occupy on iOS.

## Layering

```
┌──────────────────────────────────────────────────────────────┐
│ DemoApp (Swift)            @State, VStack, Text, Button ... │  ← unmodified SwiftUI style source
├──────────────────────────────────────────────────────────────┤
│ SwiftUI (Swift, portable)  ViewGraph · State · Layout ·      │
│                            DisplayList                       │
├──────────────────────────────────────────────────────────────┤
│ SwiftUIAndroid (Swift)     App runtime, renderer, hit-test,  │
│                            animation clock, JNI glue         │
├──────────────────────────────────────────────────────────────┤
│ AndroidBridge (C)          JNI entry points, cached method   │
│                            IDs, Canvas/Paint/Typeface        │
├──────────────────────────────────────────────────────────────┤
│ Android platform           android.graphics.Canvas (Skia),   │
│                            Paint text shaping, View, MotionEvent │
└──────────────────────────────────────────────────────────────┘
```

The portable `SwiftUI` target contains **no** platform calls, so the same layout/state code
also builds and unit-tests on macOS (`swift test`), which is how we validate the engine
without a device.

## Rendering model (3 passes, like SwiftUI)

1. **Resolve** — walk the view tree, evaluate `body`, install dynamic properties
   (`@State`, `@Binding`, `@StateObject`, `@Environment`), produce an `Element` tree.
   Composite views recurse through `body`; primitive views produce leaf elements.
2. **Layout** — `sizeThatFits(ProposedViewSize)` top-down, `place(in:)` assigning absolute
   frames in *points (dp)*, bottom-up size caching. Stacks negotiate along their axis,
   `Spacer` takes the flexible remainder, `padding`/`frame` wrap.
3. **Paint** — walk the placed tree and emit a flat `[DrawCommand]` display list in
   absolute dp coordinates. The Android renderer replays it into `Canvas` via the C bridge.

State mutation marks the graph dirty and schedules exactly one `invalidate()` for the next
vsync; the display list is rebuilt on the UI thread inside `onDraw`.

Coordinate system: top-left origin, +y down, unit = dp. The Java host scales the canvas by
`density` once, so the entire Swift/SwiftUI layer works in dp and never sees pixels.
Text: `Paint.textSize` is set in dp for the same reason, so `measureText` also returns dp.

## Threading

* All of SwiftUI state mutation and rendering happens on the Android **UI thread**
  (`postInvalidate()` is the only cross-thread call, and it is thread-safe).
* `JNI_OnLoad` caches the `JavaVM`; the bridge caches `jmethodID`s per thread.
* `invalidate` is posted back through the host `View`; no Java calls from arbitrary threads.

## Target SDK / ABI

* `minSdk 28`, `targetSdk 35`, `compileSdk 35`
* Swift triple: `aarch64-unknown-linux-android28` (plus `x86_64-unknown-linux-android28`
  for emulators when needed)
* Official Swift SDK for Android `swift-6.4.3-RELEASE_android`, NDK r30 LTS

## Directory layout

```
Package.swift
Sources/
  AndroidBridge/        C shim: JNI entry points + Canvas drawing API   (target AndroidBridge)
    include/AndroidBridge.h
  SwiftUI/              portable framework core                          (target SwiftUI)
  SwiftUIAndroid/       Android runtime + renderer + JNI glue            (target SwiftUIAndroid)
  DemoApp/              the demo app written in SwiftUI style            (target DemoApp)
app/                    Java host (Activity, View), manifest, resources
scripts/                build-apk.sh, run-emulator.sh
Tests/SwiftUITests/     host-side layout/state tests
```

## Milestones

* **M1** toolchain: OSS Swift 6.4.3 + Android SDK + NDK r30, cross-compiles `main.swift`.
* **M2** bridge + host app: APK builds, native lib loads, canvas draws a solid frame.
* **M3** engine: `View`/`ViewBuilder`/`@State`, stacks, text, shapes, modifiers, layout.
* **M4** demo app on emulator, screenshots verified pixel-by-pixel through `adb`.
* **M5** polish: animations, ScrollView/List, gestures, dark mode, hit-testing.
```
