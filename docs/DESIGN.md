# Design — porting the closed-source SwiftUI to Android

## 1. The problem, stated precisely

Apple's `SwiftUI` is closed source and Darwin-only. Its binary (`SwiftUI.framework/SwiftUI`,
plus the `SwiftUICore` split introduced in iOS 18) is a Mach-O dylib whose engine binds to:

* **UIKitCore** for view hosting, gestures, text input, and traits
* **QuartzCore / CA::Render** for compositing, animation, and layer trees
* **Metal / IOSurface** for rasterisation
* **CoreText / CoreGraphics** for text shaping and metrics
* plus `Combine`, `CoreFoundation`, `Observation`, `Symbols`, `Spatial`, `os`, `simd`

`SwiftUI.tbd` confirms the reexports (`SwiftUICore`, `UIKit`, `CoreTransferable`,
`DeveloperToolsSupport`). Loaded on Android, the binary would need every one of those
frameworks supplied at binary level — that is porting iOS's userland, and the Metal dependency
cannot be satisfied at all.

**So there is no configuration in which Apple's compiled SwiftUI executes on Android.** Anyone
claiming otherwise is either streaming a Mac/simulator (remote rendering) or reimplementing.

## 2. What *is* portable, and what this port therefore does

Apple publishes the framework's complete API as textual module interfaces inside the iOS SDK.
Those files are not documentation: they are the compiler's authoritative view of the module.
The Swift frontend recompiles them for the current target; only the embedded `-target` header
pins them to Apple.

| Artifact | Size | Declarations | `@inlinable` bodies |
|---|---|---|---|
| `SwiftUI.swiftinterface` | 1.9 MB / 33,818 lines | 6,239 | 273 |
| `SwiftUICore.swiftinterface` | 1.4 MB / 27,839 lines | 2,533 | 749 |
| `Symbols.swiftinterface` | 637 lines | — | — |
| `Combine.swiftinterface` | 2,590 lines | — | — |

The port consumes those files, so **the API surface an app compiles against is Apple's,
byte-for-byte** — types, generic signatures, availability, result builders, property-wrapper
contracts, SPI. `@inlinable` bodies are real Apple code and are preserved verbatim; they then
execute natively on Android, compiled by the official Swift SDK for Android.

Everything else — the 1,900 bodyless functions and the bodyless properties/inits in SwiftUI
alone — is the part a port must implement: the engine, in Swift, on top of Android's native
canvas.

### Retargeting rules (all mechanical, all documented)

`scripts/port/retarget_interface.py` rewrites only the module header and ObjC-only metadata:

| Rule | Why |
|---|---|
| `-target arm64-apple-ios*` → `-target aarch64-unknown-linux-android28` | the interface is recompiled for the port's target |
| drop `-enable-objc-interop`, strip `@objc`/`@nonobjc` attributes | no ObjC runtime on Android; attributes carry no Swift ABI meaning there |
| rewrite `// swift-compiler-version` and drop `-interface-compiler-version` | the SDK's compiler stamp is 6.4.2, the OSS toolchain is 6.4.3; the check is metadata-only |
| drop self `@_exported import <Self>` / `import <Self>.<Sub>` | they resolve the ObjC "underlying module", which does not exist off-Darwin |

Nothing else is touched. Declaration text stays identical; a `git diff` of
`build/port-sdk/gen` against Apple's files shows only those header lines.

### Shims (declarations only)

Modules that have no Android counterpart get shims under `port-shims/`: `UIKit`,
`CoreGraphics`, `CoreFoundation`, `QuartzCore`, `CoreText`, `CoreData`, `CoreMedia`,
`DataDetection`, `UniformTypeIdentifiers`, `Accessibility`, `Spatial`, `simd`, `Darwin`, `OSLog`,
`os`, `CoreTransferable`, `DeveloperToolsSupport`. Each shim declares exactly the subset the
retargeted Apple interfaces reference, with signatures copied from Apple's own interface/headers
and `fatalError()` bodies; behaviour is supplied by the port's runtime. `docs/PORT-SDK.md`
tracks coverage and semantic gaps.

## 3. Runtime architecture

Apple's interfaces expose the engine seam itself — `View` is not just `body`:

```swift
public protocol View {
  nonisolated static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs
  nonisolated static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs
  nonisolated static func _viewListCount(inputs: _ViewListCountInputs) -> Int?
  associatedtype Body: View
  @ContentBuilder var body: Body { get }
}
```

`_GraphValue`, `_ViewInputs`, `_ViewOutputs`, `_ViewListInputs`, `_ViewListOutputs` are opaque
in the interface (all their storage is internal), which is exactly what a port needs: the port
gives them real contents and implements `_makeView` for each primitive.

Pipeline per frame:

```
root View ──_makeView────▶ value graph (_GraphValue/_ViewInputs) ──▶ node tree
                                                                    │
                                          layout: propose → sizeThatFits → place
                                                                    │
                                          paint:  node tree → [DisplayCommand] (dp, absolute)
                                                                    ▼
                             SwiftUIAndroid.AndroidCanvasPainter ──▶ ab_* (C) ──▶ Canvas (Skia)
```

* **State**: `@State`/`@Binding`/`@StateObject`/`@Environment` are implemented as property
  wrappers keyed by structural identity; mutation marks the graph dirty and posts one
  `invalidate()` for the next vsync (thread-safe via `View.postInvalidate()`).
* **Geometry**: everything in dp. The Java host applies `canvas.scale(density)` once, so the
  Swift layer never sees pixels; text sizes are set in dp so `measureText` also returns dp.
* **Display list**: `Sources/SwiftUI/Engine/DisplayList.swift` — a platform-free command list
  (rects, rounded rects, ovals, paths, text, gradients, shadows, clip/opacity) that the Android
  painter replays. It is the testable heart of the port and the boundary a future backend
  (Vulkan/Skia-NDK) would implement.
* **Platform**: `Sources/SwiftUIAndroid/AndroidRuntime.swift` exports the seven C-linkage JNI
  entry points, owns the frame loop, and converts commands into `ab_*` calls.
  `Sources/AndroidBridge/AndroidBridge.c` owns all `JNIEnv` handling, caches `Paint`/`Path`/
  `Typeface`, and never lets Java objects cross into Swift.

## 4. Threading

Every entry point runs on the Android UI thread. `ab_invalidate` is the only cross-thread call
and is thread-safe (`postInvalidate`). No Java object reference escapes the C layer; Swift sees
floats, `uint32_t` ARGB and UTF-8 byte buffers.

## 5. Provenance and licensing

The port's code is MIT ([LICENSE](../LICENSE)). The declarations under
`Sources/SwiftUI/Generated/` and the API re-declarations under `port-shims/` are Apple's,
mechanically extracted or transcribed from the publicly shipped SDK interfaces and headers — the
same metadata a linker stub or framework header carries. No Apple binaries are redistributed or
executed. [NOTICE](../NOTICE) separates that material, and the vendored OpenCombine under
`Sources/Combine/`, from the MIT-licensed work.

## 6. Deliberate limits

* No Metal backend: the port targets `android.graphics.Canvas`, which is hardware accelerated in
  the same way CoreGraphics/UIKit drawing is on iOS.
* No ObjC interop: UIKit-dependent API (e.g. `UIViewRepresentable` bridging to a real `UIView`)
  can only be declarative on Android until a UIView-equivalent bridge exists.
* Accessibility is not implemented, and there is no image decoding: `Image(systemName:)` maps the
  symbol name onto the closest text glyph, so symbol-heavy layouts are approximations.
* Text input *is* implemented, through a platform seam: an invisible Android `EditText` owns the IME
  while SwiftUI keeps the styling and the binding ([GALLERY.md](GALLERY.md)).
