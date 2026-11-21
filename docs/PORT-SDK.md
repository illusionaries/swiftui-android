# The Port SDK — Apple's real SwiftUI interfaces, retargeted to Android

`build/port-sdk/` is the "Port SDK": a directory of *module interfaces* that makes
`import SwiftUI` work for `aarch64-unknown-linux-android28` with Apple's own declarations.

Nothing in it is a reimplementation of SwiftUI. It contains:

1. **Apple's real `.swiftinterface` files**, extracted from the iOS 27 simulator SDK and
   mechanically retargeted (only the `-target` header and a closed set of ObjC-only
   spellings change; see [the rule table](#retarget-rules-r1r14)).
2. **Platform shims** — hand-written, declaration-only Swift modules for the Darwin
   frameworks that have no Android counterpart (`UIKit`, `CoreGraphics`, `QuartzCore`, ...).
   Every declaration in them is copied from Apple's shipped headers/interfaces.
3. A **probe** (`scripts/port/probe.swift`) that is ordinary iOS-style SwiftUI code and is
   typechecked against the lot. It is the fidelity gate.

**Status: `./scripts/port/build-port-sdk.sh` → `probe errors: 0`.** Apple's
33,818-line `SwiftUI` interface and 27,839-line `SwiftUICore` interface both recompile for
Android and a real SwiftUI app typechecks against them, including `@State` (whose *macro*
is expanded by Apple's own host plugin, see [macros](#macros-state-preview-work)).

## TL;DR

```sh
./scripts/port/build-port-sdk.sh            # retarget + shims + probe  (0 errors expected)
./scripts/port/build-port-sdk.sh --clean    # rebuild from scratch (same result)
./scripts/port/build-port-sdk.sh --no-probe # skip the probe while iterating on a shim
./scripts/port/check-module.sh SwiftUICore  # compile `import SwiftUICore` alone, print only its errors
```

Outputs:

```
build/port-sdk/gen/<Module>.swiftmodule/<triple>.swiftinterface    # retargeted Apple interfaces
build/port-sdk/shims/<Module>.swiftmodule/<triple>.swiftinterface   # platform shims
build/port-sdk/probe.log                                            # empty when the probe is green
build/port-sdk/.module-cache/                                       # compiler module cache
```

Both `gen` and `shims` are passed to the compiler with `-I`.

## Module inventory

Derived from the retargeted interfaces: `SwiftUI` is the module applications import;
`SwiftUICore` is the engine half that `SwiftUI` re-exports.

| Module | Kind | Source of truth | Lines (in → out) | Declarations | Notes |
|---|---|---|---|---|---|
| `SwiftUI` | **real, retargeted** | `SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64-apple-ios-simulator.swiftinterface` | 33,818 → 30,702 | 5,643 | The whole public framework. |
| `SwiftUICore` | **real, retargeted** | same shape, `SwiftUICore.framework` | 27,839 → 27,231 | 5,652 | Includes the `@State`/`@Binding`/… macro declarations. |
| `Combine` | **real, retargeted** | `Combine.framework` | 2,590 → 2,590 | 1,367 | Needed by `SwiftUI` (and by `SwiftUICore`). |
| `Symbols` | **real, retargeted** | `Symbols.framework` | 637 → 637 | 194 | SF Symbols API surface. |
| `DeveloperToolsSupport` | **real, retargeted** | `DeveloperToolsSupport.framework` | 230 → 222 | 65 | Previews / `ImageResource` / `ColorResource`. |
| `CoreGraphics` | shim | `CoreGraphics.framework/Headers` + its Swift overlay | — → 173 | 110 | CG value types (4 are aliases to Foundation's). |
| `UIKit` | shim | `UIKit.framework/Headers` + overlay `UIKit.swiftinterface` | — → 501 | 164 | 40 `UI*` names SwiftUI references. |
| `FoundationShims` | shim | `Foundation.framework/Modules/Foundation.swiftmodule/…swiftinterface` + headers | — → 175 | 99 | Foundation API the Android SDK does not ship. **Port-only module name.** |
| `CoreText` | shim | `CoreText.framework/Modules/CoreText.swiftmodule/…swiftinterface` + `CTFont.h` | 112 → 98 | 48 | `AttributedString` attribute keys + `CTFont`. |
| `Spatial` | shim | `usr/include/Spatial/Structures.h` | — → 74 | 44 | `Size3D`/`Vector3D`/`Rotation3D`/`Pose3D`. |
| `QuartzCore` | shim | `QuartzCore.framework/Headers` | — → 43 | 27 | `CALayer`, `CATransform3D`. |
| `os` | shim | `usr/lib/swift/os.swiftmodule` overlay | 2,602 → 43 | 27 | `OSLog`, `OSLogMessage`, `os_log`. |
| `CoreTransferable` | shim | `CoreTransferable.framework/Modules/…swiftinterface` | 258 → 83 | 42 | **Not retargetable** — see gaps. |
| `Accessibility` | shim | `Accessibility.framework/Headers` + overlay | 414 → 55 | 19 | `AXChartDescriptor`, `AXCustomContent`. |
| `CoreData` | shim | `CoreData.framework/Headers` | — → 33 | 3 | 5 managed-object names used in signatures. |
| `ObjectiveC` | shim | `NSObject.h` | — → 25 | 12 | `NSObject`/`Selector`, aliasing Foundation where it can. |
| `UIUtilities` | shim | `UIKit.framework/Headers/UIUtilities.h` | — → 22 | 12 | `UIRectEdge` (Apple submodule name). |
| `UniformTypeIdentifiers` | shim | `UniformTypeIdentifiers.framework` (Clang only) | — → 28 | 17 | `UTType`. |
| `DataDetection`, `CoreMedia`, `Darwin`, `OSLog`, `simd` | import-only shims | — | 8 each | 0 | The interfaces `import` them but reference nothing; they exist so the import resolves. |

Shim totals: **1,653 lines of Swift**, 18 modules, 554 public declarations.

Not modules of their own: `Foundation`, `Observation`, `Dispatch`, `_Concurrency`,
`_StringProcessing`, `_SwiftConcurrencyShims`, `Android` all come from the official
**Swift SDK for Android** (`swift-6.4.3-RELEASE_android`) and are used as shipped.

## Retarget rules (R1–R14)

`scripts/port/retarget_interface.py` is the whole transformation. It is intentionally a
*closed* list: every rule is mechanical, documented in the script's docstring, and leaves
declaration text byte-identical except where the rule is about a spelling that cannot exist
off-Darwin.

| Rule | Change | Why |
|---|---|---|
| **R1** | `-target` → `aarch64-unknown-linux-android28`; drop `-enable-objc-interop`; blank the `swift-compiler-version` / `-interface-compiler-version` pins | The interface is *recompiled* for the new target; the pins otherwise make the frontend refuse it ("this SDK is not supported by the compiler"). The stamp is emitted by `compiler_version_stamp()`, which runs `swift --version` on `PATH` and writes `Apple Swift version 6.4.3 (retargeted)` — a literal stamp is parsed as a version and rejected. |
| **R2** | drop `@_exported [public] import <Self>` | In Apple's SDK that line imports the framework's *Clang umbrella module*, which shares the Swift module's name. No Clang module exists on the port, and a module cannot import itself. |
| **R3** | drop `import <Self>.<submodule>` | Same reason, dotted form. |
| **R4** | `import X.Y` → `import X` | Clang submodules (`os.log`, `os.lock`) have no equivalent; the parent module carries the declarations. |
| **R5** | auto-insert `import M` for every Port SDK module the interface references by qualified name but does not import, plus `import Android` | Darwin resolves `QuartzCore::CALayer`, `CoreText::CTFont`, `ObjectiveC::NSObject` through an implicitly-loadable SDK; on the port the module must be imported. `Android` is the SDK's C-library overlay (the `Darwin`/`Glibc` equivalent) and is where `exp2(Float)` comes from — `SwiftUICore.Color.exposureAdjust` calls it unqualified. |
| **R6** | `CoreFoundation::CGFloat/CGPoint/CGSize/CGRect/CGVector/CGAffineTransform` → `CoreGraphics::…` (both `::` and `.` spellings) | On Darwin those six are declared in `CoreFoundation/CFCGTypes.h`. Android's `CoreFoundation` is the corelibs Clang module with no CG types, and *shadowing* it would break `Foundation` (whose public API references `CFString`, …). The `CoreGraphics` shim declares exactly those six. |
| **R7** | strip `@objc`, `@objc(name)`, `@nonobjc` | No ObjC runtime on Android; the attribute only expresses ObjC exposure. Swift signatures unchanged. |
| **R8** | drop `@available(iOS, unavailable)` / `@available(macOS, unavailable)` | Apple-platform availability is noise for an Android target. |
| **R9** | drop `: BitwiseCopyable` conformance clauses (whole conformance-only extensions too) | On Darwin the CG geometry types are C structs and therefore `BitwiseCopyable`; on the port they are corelibs Foundation structs, and *retroactive* conformance to a marker protocol is rejected ("conformance must occur in the same module"). SE-0426 codegen hint, no API surface. |
| **R10** | requalify Foundation API the Android SDK lacks: `LocalizedStringResource`, `NSItemProvider`, `NSUserActivity`, `NSFileCoordinator`, `FileWrapper`, `UndoManager`, `NSKeyValueChangeKey`, `AttributeRunBoundaries`, `Date.ComponentsFormatStyle(.Field)`, `Date.RelativeFormatStyle(.Field)`, `Locale.Language`, `NumberFormatStyleConfiguration.SignDisplayStrategy`, `AttributeScopes.FoundationAttributes` → `FoundationShims`; `Foundation.URLRequest`/`URLSession` → the **real** `FoundationNetworking` module | The Swift SDK for Android ships a reduced, non-resilient Foundation. Each requalified type is declared in `FoundationShims` from Apple's `Foundation.swiftinterface`/headers. |
| **R12** | drop `typealias X = @_opaqueReturnTypeOf("<mangled>", 0) __` | That attribute binds a name to the opaque result type of a declaration in a *prebuilt binary* module, by mangled symbol. Recompiling from text leaves nothing to look it up in. Dropping the alias lets the associated type be inferred from the `some`-typed witness — the same mechanism as `var body: some View` in ordinary SwiftUI code. Validated on SwiftUICore's 6 `InsetShape` and 50 `Body` aliases, then SwiftUI's 369. |
| **R13** | `[CGFloat]()` → `Array<CGFloat>()` | With `-enable-upcoming-feature MemberImportVisibility` (which Apple's interfaces set), an unqualified type alias in `[T]()` parses as an array literal of the metatype. Identical expression, different spelling. |
| **R14** | initializers in `extension UIKit.UISceneSessionActivationRequest` become `convenience` | Swift forbids adding a *designated* initializer to a class from another module unless the class is `@objc`. Caller-visible API is identical. This is the only occurrence in the ported interfaces. |
| **R11** | `--supplement=<path>` appends declaration-only text to a retargeted interface | Available mechanism for a module whose Swift interface is pure Swift but also needs Clang-only types. Not used today: `CoreText` and `Accessibility` became ordinary shims instead, which was simpler than maintaining a supplement per module. |
| *(pass)* | `drop_dangling_attributes()` | R9/R12 delete declarations; the `@available`/`@_originallyDefinedIn` lines that qualified them would be left in front of `}` / `#else` / EOF. Only lines consisting *solely* of attributes (balanced-paren scan) are removed, so a declaration that starts with an attribute on the same line is preserved. |

Every rule is validated by the probe: if a rule were wrong, the declarations that depend on
it would stop typechecking.

## Macros (`@State`, `@Preview`) work

SwiftUI's `@State` is a **macro** in this SDK: the interface declares
`#externalMacro(module: "SwiftUIMacros", type: "StateMacro")`. The implementation is a
*host-side compiler plugin* — a macOS dylib that emits Swift source and never runs on the
target. Xcode ships it at
`…/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib`,
and the plugin server is part of the OSS toolchain
(`$SWIFT_TOOLCHAIN/usr/bin/swift-plugin-server`). `build-port-sdk.sh` locates both and
passes `-external-plugin-path <dir>#<server>`, so cross-compiling for Android still expands
Apple's macros. This is not a reimplementation: it is Apple's macro implementation producing
its own expansions.

Note that the *simulator* platform directory does not ship the plugin — the iPhoneOS one
does. The script probes the SDK, the platform, and the MacOSX platform directory, in that
order.

## Semantic gaps

These are the places where the port's API surface is declaration-identical but *means*
something different. Everything else is Apple's own text.

| # | Gap | Where it shows | Consequence / mitigation |
|---|---|---|---|
| 1 | **No Objective-C runtime.** ObjC classes are ordinary Swift classes; `ObjectiveC.NSObject` is `Foundation.NSObject` (corelibs), `Selector` is a plain struct. ObjC-only members (`class`, `superclass`, `isKind(of:)`, `responds(to:)`, `#selector`) are not declared. | `UIKit` shim, `ObjectiveC` shim | Nothing on Android uses those members. Reviewed by the compiler: every declaration in `UIKit`/`CoreGraphics`/… that SwiftUI references typechecks. |
| 2 | **No Core Animation, no Metal.** `CALayer`, `CATransform3D` are declaration-only; `CGContext`/`CGPath`/`CGImage`/`CGColor` carry no drawing. | `QuartzCore`, `CoreGraphics` shims | Views that ask for a layer render through the engine's own display list instead. `_CALayerView`/`GraphicsContext` entry points trap until the runtime serves them. |
| 3 | **`CoreTransferable` cannot be retargeted.** Its interface declares `Data`/`URL`/`AttributedString` conformances to `Transferable` whose witnesses are `@_opaqueReturnTypeOf` opaque types and whose `CodableRepresentation` needs `JSONEncoder: TopLevelEncoder`. Recompiling it against the Android SDK's *non-library-evolution* Foundation is rejected outright. | `port-shims/CoreTransferable` | The module is a declaration-faithful shim: `Transferable`, `TransferRepresentation`, the representation structs, and inert `Never`/`String`/`URL`/`Data` conformances (Apple declares those four). Drag & drop / share sheets do nothing on Android. |
| 4 | **12 Foundation types are absent from the Swift SDK for Android**, plus `String.StandardComparator.localizedStandard`. | `FoundationShims` | Declared with Apple's signatures and *subset* member sets (each type's header comment says which members and why). `URLRequest`/`URLSession` are the real ones, from `FoundationNetworking`. |
| 5 | **`BitwiseCopyable` conformances dropped** (R9). | all retargeted modules | Codegen hint only; a few `@inlinable` bodies lose an optimization, none change behaviour. |
| 6 | **`@_opaqueReturnTypeOf` aliases dropped** (R12). | all retargeted modules | `Body`/`InsetShape`/`Representation` are inferred from the `some` witness. Public API identical. |
| 7 | **`UISceneSessionActivationRequest.init?(hostingDelegateClass:…)` is `convenience`** (R14). | `SwiftUI` | Swift language restriction, caller-visible API identical. |
| 8 | **`@MainActor` is modelled on the view/controller hierarchy but not on leaf classes** (`UIColor`, `UIImage`, `UITraitCollection`). | `UIKit` shim | Single UI thread on Android; no data race is possible. SwiftUI's own isolation is untouched. |
| 9 | **`Spatial.Size3D` and `Spatial.Vector3D` are one type** (`Vector3D` is a typealias). On Darwin they are distinct C structs. | `Spatial` shim | Only needed because SwiftUICore's visionOS `Animatable` extension declares `animatableData: Vector3D` *and* `typealias AnimatableData = Size3D`. visionOS API never executes on Android. |
| 10 | **`UIColor`/`UIImage`/`UIFont` are declaration-faithful, not pixel-faithful.** | `UIKit` shim | The runtime maps them to `android.graphics.Color`/`Bitmap`/`Typeface`. |
| 11 | **`CoreData`, `CoreMedia`, `DataDetection`, `simd`, `OSLog`, `Darwin` declare nothing.** | import-only shims | Their names appear in `import` lines and in a handful of signatures; there is no behaviour to port. |
| 12 | **No ABI/library-evolution guarantee.** Shims are compiled with `-enable-library-evolution`, but the Android SDK's `Foundation` is not resilient, so a module that links shim types against Foundation in its *public* API only gets a warning ("binary compatibility … can't be guaranteed"). | build output | Irrelevant: the Port SDK is rebuilt from source for each ABI; there is no binary distribution. |

## Using the Port SDK from SwiftPM

`Package.swift` already points at the Port SDK (it is the `includeGeneratedPort` path):

```swift
let portSDKFlags: [String] = [
    "-I", packageDirectory + "/build/port-sdk/gen",
    "-I", packageDirectory + "/build/port-sdk/shims",
    "-enable-experimental-feature", "AnyAppleOSAvailability",
]
```

That is enough for `import SwiftUI` and for compiling SwiftUI *code*. Three more things are
required, and they come from the build invocation rather than the package manifest:

| Need | Flag | Why |
|---|---|---|
| Android SDK + sysroot | `--swift-sdk swift-6.4.3-RELEASE_android`, or `-sdk <swift-android>/ndk-sysroot -resource-dir <swift-android>/swift-resources/usr/lib/swift-aarch64` | Foundation/Observation/Dispatch and the C library for Android. |
| Apple's macro plugins | `-external-plugin-path <host/plugins>#<toolchain>/usr/bin/swift-plugin-server` | `@State`, `@Binding`, `@Preview` … are macros. `build-port-sdk.sh` prints the directory it picked. |
| Availability | `-enable-experimental-feature AnyAppleOSAvailability` | Apple's interfaces are annotated `@available(iOS …, visionOS …, *)`; this lets them compile for a non-Apple target. Swift 5 language mode (`-swift-version 5`) must be kept — it matches Apple's own `-language-mode 5`. |

Full manual invocation (what the probe does):

```sh
swiftc -typecheck app.swift -module-name DemoApp \
  -target aarch64-unknown-linux-android28 \
  -resource-dir "$SWIFT_ANDROID_SDK/swift-resources/usr/lib/swift-aarch64" \
  -sdk "$SWIFT_ANDROID_SDK/ndk-sysroot" \
  -I build/port-sdk/gen -I build/port-sdk/shims \
  -module-cache-path build/port-sdk/.module-cache \
  -enable-experimental-feature AnyAppleOSAvailability \
  -external-plugin-path "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins#$(dirname "$(which swiftc)")/swift-plugin-server" \
  -swift-version 5
```

Environment the script honours. Every one of these is resolved by `scripts/env.sh` — the
exported value wins, then a gitignored `scripts/local.env`, then the conventional install
location — so a checkout with a normal toolchain setup needs none of them set.
`./scripts/env.sh --check` prints the resolved values.

| Variable | Resolved to |
|---|---|
| `APPLE_SDK` | the iOS simulator SDK inside the selected Xcode (`xcode-select -p`) |
| `SWIFT_TOOLCHAIN` | an installed Swift 6.4.3 OSS toolchain (root, `.xctoolchain`, or unpacked `.pkg` `Payload`) |
| `SWIFT_ANDROID_SDK` | `<swift-sdks>/swift-6.4.3-RELEASE_android.artifactbundle/swift-android` |
| `ANDROID_NDK_HOME` | an NDK r27 or newer (the shipped SDK is built against r30) |
| `PORT_MACRO_PLUGIN_DIR` | Xcode's `…/usr/lib/swift/host/plugins`, which contains `libSwiftUIMacros` |
| `TARGET_TRIPLE` | `aarch64-unknown-linux-android` |

`Package.swift` keeps the generated port opt-in with `SWIFTUI_PORT_GENERATED=1` because the
engine (`Sources/SwiftUI/Engine`) and its adapters are still being written against these
declarations; the Port SDK probe itself (this document's contract) is green.

## What the runtime implementer must provide

The Port SDK is typecheck-only. It compiles, but nothing in a shim does anything. The
Android runtime target is expected to satisfy this contract:

**SwiftUI-level entry points the engine owns.** Every declaration in `gen/SwiftUI` and
`gen/SwiftUICore` is an unresolved external symbol until `Sources/SwiftUI/Engine` provides
it. Practically, the engine implements the *programming model* (`View`, `ViewBuilder`,
`DynamicProperty`, layout, display list) — that is the port's real work and it is why the
probe is the gate: the shapes it must implement are exactly Apple's.

**Platform entry points the shims stand in for** (these are the ones a renderer must call or
replace; each currently traps):

| Shim | Entry points | What the engine does |
|---|---|---|
| `CoreGraphics` | `CGColor` (components/alpha), `CGPath`/`CGMutablePath` (empty), `CGImage` (width/height), `CGAffineTransform` (identity, concatenating, inverted, decomposed), `CGVector`, `CGLineCap`/`CGLineJoin` | Real geometry math where it is pure value semantics; `android.graphics.Path`/`Canvas` for path/pixel types. |
| `UIKit` | `UIView` (frame/bounds/transform/layer/hit-test/layout hooks), `UIViewController` (lifecycle), `UIColor` (→ `android.graphics.Color`), `UIImage` (→ `Bitmap`), `UIContentView`/`UIContentConfiguration` | Bridge a hosting view to an Android `View`: `onDraw` → display list replay, `onTouchEvent` → gesture/hit-test, `onMeasure` → `sizeThatFits`/`place`. |
| `QuartzCore` | `CALayer`, `CATransform3D` | Not implemented; layer-backed views render through the same display list path. |
| `CoreText` | `CTFont`, `AttributedString` attribute keys | Text goes through `Paint`/`Typeface`; `CTFont` is a token. |
| `os` | `OSLog`, `OSLogMessage`, `os_log` | Route to `android.util.Log` through the JNI bridge (the shim is currently silent). |
| `CoreTransferable` | `Transferable.transferRepresentation` | Share sheet / drag & drop equivalent, or nothing. |
| `FoundationShims` | `LocalizedStringResource`, `NSItemProvider`, `UndoManager`, … | Only if the app uses those APIs. |
| `Accessibility`, `Spatial`, `CoreData`, `CoreMedia`, `DataDetection`, `UniformTypeIdentifiers` | — | Accessibility maps to `AccessibilityNodeInfo`; the rest have no Android counterpart. |

**Macro expansion** is a *build-time* dependency on Apple's plugin dylib (see
[macros](#macros-state-preview-work)), not a runtime one.

## Verification and maintenance

* **Probe** — `scripts/port/probe.swift` is ordinary SwiftUI code (`NavigationStack`,
  `ScrollView`, `ForEach`, `@State`, `Button`, `Circle().fill`, `.padding`, `.font`,
  `Divider`, `Color`, `Capsule`, `.preferredColorScheme`). It typechecks against the real
  interfaces. Keep it boring; it is a gate, not a demo.
* **Idempotence** — run the build twice (and once with `--clean`); all three report
  `probe errors: 0`. The module cache can hide a stale interface, so `--clean` is the
  trustworthy run.
* **Localizing a failure** — `scripts/port/check-module.sh <Module>` compiles a one-line
  `import <Module>` and prints only that module's errors. `SwiftUI`/`SwiftUICore` emit
  errors *from* the interfaces they import, so the failing module is usually not the one you
  edited.
* **Adding a module** — put `port-shims/<Name>/<Name>.swift` in place and add `<Name>` to
  `shim_modules` in dependency order; if Apple ships a `.swiftinterface` for it and it has no
  ObjC-rooted declarations, add it to `real_modules` instead and let `retarget_interface.py`
  handle it.
* **Changing a rule** — extend the docstring in `scripts/port/retarget_interface.py` first,
  then the code. Rules are reviewed against the probe: a wrong rule shows up as declarations
  that stop typechecking.
* **Never** add `-enable-objc-interop`, never hand-edit `build/port-sdk/gen/**`, and never
  delete a declaration from a retargeted interface to make an error go away — if something
  genuinely cannot exist off-Darwin, add it to the gap table above and (if it is a spelling)
  to the rule table.

### Error-count history

Recorded while building this SDK, for calibration when something regresses:

| State | Probe errors | Cause |
|---|---|---|
| initial | 94 | `@objc`/`@objc deinit` in Apple's interfaces + broken compiler-version stamp + missing `UIKit`/`CoreGraphics` |
| after R7, R1 | 44 | all from retargeting `CoreTransferable` against non-resilient Foundation |
| after demoting `CoreTransferable` to a shim | 52 → 12 | `SwiftUICore` missing QuartzCore/CoreText/ObjectiveC/`FoundationShims` types |
| after `FoundationShims` + small shims + R10/R12/R13 | 0 (`SwiftUICore`) | — |
| after the `UIKit` shim + R14 | 166 → 0 (`SwiftUI`) | member-by-member `override` errors name exactly what UIKit had to declare |
| after `-external-plugin-path` | **0** (probe) | `@State` is a macro; Apple's host plugin expands it |
