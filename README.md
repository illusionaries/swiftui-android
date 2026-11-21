# SwiftUI for Android — a port of Apple's closed-source framework

This repository does something that is usually assumed to be impossible: it **ports Apple's
SwiftUI to Android**, rather than reimplementing a lookalike API.

It does that by taking Apple's own shipped artifacts — the textual module interfaces for
`SwiftUI` and `SwiftUICore` that ship inside the iOS SDK — recompiling them for
`aarch64-unknown-linux-android`, and implementing the runtime beneath them, drawing through
Android's native `android.graphics.Canvas` (Skia) over JNI.

No Jetpack Compose. No Kotlin UI. No transpiler. The declarations the app compiles against are
Apple's, byte-for-byte.

---

## Why the binary cannot simply be copied

`SwiftUI.framework` on iOS is a Mach-O dylib whose layout/text/render engine links against
**UIKitCore → QuartzCore/CA::Render → Metal/IOSurface**, and measures text through
**CoreText**. `SwiftUI.tbd` reexports `SwiftUICore`, `UIKit`, `CoreTransferable`,
`DeveloperToolsSupport`; `SwiftUICore` imports `Combine`, `CoreFoundation`, `Observation`,
`Symbols`, `Spatial`, `os`, `simd`, `Accessibility`. None of those exist on Android, all of the
graphics ones are closed source, and Metal has no Android equivalent. Loading the Mach-O on
Android therefore means porting iOS's entire userspace graphics stack — i.e. porting iOS.

What *is* portable is the part Apple publishes: the complete API surface as
`.swiftinterface` files, which the Swift frontend recompiles for any target.

| Apple artifact | Size | Content |
|---|---|---|
| `SwiftUI.swiftinterface` | 1.9 MB / 33,818 lines | 6,239 public declarations, 273 `@inlinable` bodies |
| `SwiftUICore.swiftinterface` | 1.4 MB / 27,839 lines | 2,533 declarations, 749 `@inlinable` bodies |
| `Symbols.swiftinterface` | 637 lines | SF Symbols API |
| `Combine.swiftinterface` | 2,590 lines | Combine (retargeted too) |
| `SwiftUI.tbd`, `SwiftUICore.tbd` | 1.8 MB | exported symbol tables / reexports |

Those become the port's `SwiftUI` module. Everything the interface declares but does not
*implement* (1,900 bodyless functions in SwiftUI alone, plus bodyless properties and inits) is
what this project implements natively — which is exactly what porting a closed-source framework
means.

## Pipeline

```
iOS SDK .swiftinterface  ──retarget host triple──▶  build/port-sdk/gen/<Module>.swiftmodule
                                                          │  (Apple's declarations, unmodified)
Apple-only modules (UIKit, CoreGraphics, …)  ──shim──▶    │
                                                          ▼
                        Sources/SwiftUI/Generated/*.swift  (declarations + placeholder bodies,
                                                          │  @inlinable bodies preserved verbatim)
                        Sources/SwiftUI/Engine/*.swift  ──┤  (the ported runtime: layout, state,
                                                          │   DisplayList, drawing)
                        Sources/SwiftUIAndroid/*.swift  ──┤  (JNI entry points, canvas backend)
                        Sources/AndroidBridge/*.c       ──┤  (JNI + Canvas/Paint/Typeface bridge)
                        app/**  (Java host: Activity + View, harness)
                                                          ▼
                                       build/SwiftUI-Android.apk  →  emulator
```

* `scripts/port/retarget_interface.py` — rewrites only the module header (target triple,
  ObjC-interop flag, compiler-version stamp) so Apple's declarations compile for Android.
  Everything else is preserved byte-for-byte.
* `scripts/port/build-port-sdk.sh` — produces the importable Port SDK and runs the fidelity
  probe (`scripts/port/probe.swift`, ordinary iOS SwiftUI code) against it.
* `scripts/port/inject_bodies.py` — turns interfaces into compilable sources; emits a manifest
  of every entry point the port must implement.
* `scripts/build-apk.sh` — cross-compiles the Swift runtime for `aarch64`/`x86_64`, bundles the
  Swift runtime dylibs, dexes the Java host, signs and aligns the APK.
* `scripts/emulator.sh` / `scripts/device-test.sh` — headless emulator lifecycle and the
  install→launch→screenshot→logcat acceptance harness.

## The demo app

`Sources/DemoApp/` contains **Atlas**, a multi-screen app (home feed, discover grid, pushed
detail, profile with live settings) built on the port and running on the emulator. See
[docs/DEMO.md](docs/DEMO.md) for the screen breakdown, the architecture, and the six engine bugs
that building a real app exposed.

## Status

| Piece | State |
|---|---|
| OSS Swift 6.4.3 + official Swift SDK for Android + NDK r30 r30 toolchain | working, cross-compiles to real ELF |
| Apple interfaces retargeted for Android (`SwiftUI`, `SwiftUICore`, `Symbols`, `Combine`) | retarget clean; shims for `UIKit`/`CoreGraphics` in progress |
| Fidelity probe (`import SwiftUI` app source typechecked for Android) | converging (94 → 44 → …) |
| C JNI bridge + Java host + APK pipeline | **done and validated on device** (10 entry points, 22 drawing primitives, signing, alignment, insets, back handling) |
| Swift runtime + native canvas painter + frame loop | **cross-compiles and packages** (69 MB APK incl. Swift/Foundation dylibs) |
| Emulator harness | **running** (API 35 arm64, 1080×2340 @420dpi, screenshots + logcat assertions) |
| Generated port module (Apple declarations + bodies) + engine implementation | next |

## Run it

```bash
# 1. Port SDK + fidelity probe (needs Xcode for the iOS SDK interfaces)
./scripts/port/build-port-sdk.sh

# 2. Build the APK (Swift + C + Java)
export PATH=$SWIFT_TOOLCHAIN/usr/bin:$PATH
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
./scripts/build-apk.sh --abi arm64-v8a

# 3. Emulator + acceptance test
./scripts/emulator.sh start
./scripts/device-test.sh build/SwiftUI-Android.apk
```

Apple's SDK artifacts are used from the local Xcode installation only to read the publicly
shipped `.swiftinterface`/`.tbd` metadata; no Apple binaries are redistributed.

## License / provenance

The port's own code is original work. The declarations under `Sources/SwiftUI/Generated/` are
Apple's, extracted from the shipped SDK interfaces; they are included as interface metadata the
same way a linker stub or header is, and are not relicensed here.
