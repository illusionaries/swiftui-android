# Port status

Living document. Updated as the port converges. Numbers are measured, not estimated.

**Where it stands.** Both demo apps — Atlas (`./scripts/dev.sh`) and the control gallery
(`./scripts/gallery.sh`) — are ordinary SwiftUI source, render on the emulator, and pass the device
gate. Apple's declarations retarget cleanly, a real SwiftUI app typechecks for Android against them
with 0 errors, and 38 host tests cover the engine ([`test.sh`](../scripts/test.sh)). What is still
missing is enumerated in [`GALLERY.md`](GALLERY.md) and in *Known semantic gaps* below. The rest of
this file is the log of how it got here.

### Open: both demos start about 12% dark

At launch, everything both apps draw is multiplied by ≈0.875 until the first window resize; opening
the IME (which resizes the window) makes it correct, and it stays correct afterwards. Measured, not
guessed: a page background of `Color(white: 0.96)` reads 215 instead of 245, a white card reads 224
instead of 255, and a white rectangle painted *by the Java view* reads 224 while a sibling plain
`View` with a white background in the same frame reads 255.

Ruled out: the engine (the Java-painted rectangle is dimmed too), the window and its background, the
compositor (no dim layer, no colour transform, window alpha 1.0), display power state, hardware vs
software rendering, the theme's `windowAnimationStyle`, the text-input child view, and a forced
relayout. `View.getAlpha()` and `getTransitionAlpha()` both report 1.0 inside `onDraw`, so the
multiply is not a view alpha; the remaining suspects are a per-layer state leaked by the app-launch
transition and the `RenderNode`/`ViewRootImpl` path. The next step is to instrument that path rather
than keep bisecting the app.

### Resolved: the build assumed one particular machine

Every script used to carry the paths of the checkout it was written in: an Android SDK under a
project-specific home directory, an unpacked toolchain `.pkg` in a cache directory, a home
directory spelled out in a comment. They now ask `scripts/env.sh`, which resolves the OSS Swift
toolchain, the Swift SDK for Android, the Android SDK with an NDK, the JDK and Xcode from — in
order — an exported variable, a gitignored `scripts/local.env`, and the conventional install
location of each tool. It also refuses an NDK older than r27 up front, instead of letting SwiftPM
fail somewhere inside Foundation, and `./scripts/env.sh --check` prints what it resolved. The
history of this repository was rewritten for the same reason: no commit names a home directory.

### Resolved: the layout defects found by reading screenshots

- **Frame placement.** A fixed frame placed its child at the frame's *full size*, so an avatar's
  initial sat in the corner. It now keeps the child's natural size and aligns it inside the box,
  while a `.infinity` maximum fills the slot it was given (that is what tab items need).
- **Flexibility propagation.** Decorating wrappers (`clip`, `shadow`, `opacity`, `offset`) now
  follow their content, and `background`/`overlay` follow their *content* rather than their
  backdrop — a flexible shape behind a pill was stretching the pill.
- **`.lineLimit`** is honoured; ignoring it made single-line labels wrap and overflow.
- **Safe area.** The root view is clamped to the inset box and the host's inset union includes the
  gesture area, so the tab bar clears the system gesture pill.
- **Stack cross-axis sizing.** A `Spacer()` made its row flexible in *both* axes, collapsing
  highlight rows to zero height; flexible children now keep their cross-axis size.

`HighlightRowTests`, `TabBarLayoutTests`, `FrameFlexibilityTests` and the frame-placement
assertions in `LayoutTests` pin all of the above.

### Historical: text rows overlapping on device

Host geometry for a `HStack { dot; Text }.padding(.vertical, 2)` row inside a `VStack(spacing: 6)`
is exact (pinned by `HighlightRowTests`), yet on the emulator the Detail screen's highlight rows
overlap. So the mismatch is between the device `TextMeasurer`'s reported metrics and where the
canvas baseline lands, not in the layout maths: measure uses `ab_font_metrics`, paint places each
line at the layout's baseline. Compare the two directly (log `ascent`/`descent` from
`ab_font_metrics` next to the painted origin) before changing any layout code — a line-height floor
was tried and correctly rejected by the existing metrics tests.

### Resolved: the full Atlas app on the ported path

`demos/AtlasSwiftUI.swift` (521 lines, four screens) used to compile for Android without running:
`@Binding`/`@ObservedObject` failed with *"generic struct 'Binding' cannot be used as an attribute"*.
Both halves of the fix landed, and had to land together:

1. `restore_property_wrapper_attributes()` in `scripts/port/inject_bodies.py` puts the
   `@propertyWrapper` spelling back on the type declarations the generator rebuilds, and is no
   longer gated behind `if False:`.
2. The `wrappedValue` declarations stay in the generated file, with bodies supplied through
   `port-impl/bodies.txt` occurrence selectors (`Symbol#1` getter, `Symbol#2` setter) — the mechanism
   first used for `LocalizedStringKey.StringInterpolation`.

Atlas now runs from that source (`Sources/DemoApp/AtlasApp.swift`) on the default build, and the
engine-level Atlas scene remains available behind `SWIFTUI_PORT_GENERATED=0` as the renderer
reference.

## The control gallery (second demo app)

`scripts/gallery.sh` builds the gallery as its own app (`dev.swiftui.android.gallery`) from the
same library; `docs/GALLERY.md` documents it. It is what forced the last round of framework work:

- **Controls became real.** `Slider`, `Stepper`, `Picker`, `TextField`, `ProgressView`, `Label`,
  `Link` and `Divider` now have storage (injected by `port-impl/storage.txt`), initialisers
  (`port-impl/bodies.txt`) and renderers (`Adapters/PortControls.swift`). Every one of them
  funnels through a single designated initialiser per type — nine of the forwarding overloads were
  initially dropped because a `#2` occurrence selector ran after its `#1`, which is why
  `bodies.txt` now lists multi-occurrence symbols highest-first.
- **Two engine primitives were added** rather than faking them with fixed-width shapes:
  `progressBar(fraction:track:fill:)` and `sliderTrack(fraction:track:fill:knob:)`, both painting
  from the placed frame, plus `PortSliderGeometry` so the knob lands under the finger.
- **Continuous gestures** are new: `LayoutNode.dragAction` + `dragTarget(at:)`, consulted before
  tap handling, is what makes a slider track the finger.
- **`.tag(_:)` is the port's own** (`_PortTagged`): Apple routes tags through a private trait
  table, so the declaration is omitted and the port keeps the tag in a wrapper the `Picker`
  reads to know each option's selection value.
- **`.labelsHidden()` is a real environment value** now (`PortEnvironment.labelsHidden`), not a
  no-op, so a toggle can render switch-only and a Label icon-only.
- **Text input runs through the platform IME.** An invisible `EditText` owns the keyboard while
  SwiftUI keeps the styling and the binding; `Adapters/PortTextInput.swift` declares the seam and
  `SwiftUIAndroid` installs it (see the diagram in `docs/GALLERY.md`). Typing requests a frame,
  since an edit arrives outside any draw.

Device-verified interactions (screenshots in `docs/screenshots/`): slider drag 50% → 87%, stepper
3 → 4, picker `Two` → `Three`, toggle on → off, and typing "Ada" through Gboard into the field.

### A packaging landmine worth remembering

`d8` 8.2.2 (build-tools 34) **crashes with an internal `NullPointerException` on any Java class that
captures its enclosing instance** — anonymous inner classes and non-static nested classes both.
Javac gives those a synthetic `this$0`. The fix is to declare listeners as `static` nested classes
that take the owner explicitly (`SwiftUIHostView.TextChangeRelay`). `scripts/build-apk.sh` now
explains that in its d8 failure path, because the error message names a class file and nothing else.

## Round: styles, scroll physics, and the platform seams

Three device-reported defects and one feature gap, all closed and re-verified on the emulator:

- **Scrolling followed the wrong distance.** `PortDragGesture.translation` is measured from
  touch-down and grows on every move event; the store added it to the *current* offset each time,
  so the page accelerated away from the finger. `ScrollModel.track(_:)` now fixes a base offset on
  `.began` and re-derives the offset from it.
- **The end of the page was unreachable.** The scroll store treated the height the parent
  *proposed* as the viewport, but the root view is placed inside the safe area (835 dp, not 891).
  `LayoutNode.layoutHook` (invoked after every placement) hands the placed frame back, the store
  adopts it as the viewport, and the offset is clamped against the real one. On device:
  `content=2013 viewport=835 max=1177 offset=1177` at the bottom, padding included.
- **A focused empty `TextField` drew its caret after the placeholder.** The insertion point of an
  empty field is the start of the field, so the caret now precedes the placeholder.
- **Styles are environment values now.** `.buttonStyle` / `.toggleStyle` / `.pickerStyle` /
  `.textFieldStyle` used to be unused stubs; they write `PortEnvironment` fields and the adapters
  draw the built-in variants (`.borderedProminent` / `.bordered` / `.plain` buttons, `.button`
  toggles, `.inline` pickers, `.plain` fields). Apple's style *types* are bodyless, so they are
  recognised by type; a custom `makeBody` stays unimplemented and documented.
- **`Link` opens its URL.** `PortLinkOpener` is a platform seam like `PortTextInput`;
  `SwiftUIAndroid` installs a handler, the host view pulls it and starts `Intent.ACTION_VIEW`.
  Verified: tapping `swift.org` logged `link open https://swift.org` and Chrome foregrounded.

## Ported path: what renders today

Every row below is Apple's API, recompiled for Android and executed by the port's engine; the
screenshot is `docs/screenshots/ported-list.png`.

| Area | Implemented |
|---|---|
| Layout | `VStack`/`HStack`/`ZStack` (variadic `TupleContent`), `Spacer`, `padding`, `frame` (fixed + flexible), alignments, `EdgeInsets`, `Edge.Set` |
| Shapes | `Rectangle`, `RoundedRectangle`, `Circle`, `Capsule`, `_ShapeView` with `Color` / `LinearGradient` fills |
| Colour & type | `Color` (statics, `init(red:green:blue:)`, `opacity`), `Font` (+`Font.Weight`), `.font`, `.fontWeight`, `.foregroundColor`, `.foregroundStyle` — `Text` styling composes on the value itself |
| Effects | `.background`, `.overlay`, `.clipShape`, `.shadow`, `.opacity`, `.cornerRadius` (via clip) |
| Interaction | `Button` (all title inits, `action:label:`), taps through the engine's hit test, `@State`, `Binding`, `LazyState` (what Apple's macro emits), string interpolation in `LocalizedStringKey` |
| Lists | `ForEach`, `ScrollView` with drag scrolling, `Axis.Set` |

Known gaps/rough edges: no animation; none of Apple's container views (`List`, `Form`,
`NavigationStack`, `NavigationView`, `TabView`) yet — the demos navigate with state instead; `@State`
slots are keyed by wrapper creation order, so a conditional that changes wrapper count shifts later
slots; and device text baselines still differ slightly from the host's metrics (see *Historical: text
rows overlapping* above). Control-level gaps — custom style bodies, `.menu`/`.wheel` pickers,
circular progress, SF Symbols drawn as text glyphs, no image decoding — are listed once, in
[`GALLERY.md`](GALLERY.md).

## The ported renderer draws (this round)

The recompiled framework now *runs on a device*: the app links Apple's declarations, the graph
context materialises a view tree, the engine measures/places/paints it, and Skia shows the result.

![Text and a padded VStack drawn from Apple's declarations](screenshots/ported-text-stack.png)

What made the difference, in order:

1. **Platform modules became package targets.** `UIKit`, `CoreGraphics`, `Symbols`, `Combine`, …
   are SwiftPM targets in the ported build instead of prebuilt interface modules linked by hand.
   SwiftPM then links their object code itself, which removed the whole "which archive member
   supplies this metadata?" class of failure.
2. **A real Combine.** Apple ships none for Android, so `Sources/Combine` vendors OpenCombine
   (MIT) at a pinned commit and compiles it under the module name `Combine`, with a pthread-based
   C helper layer in `Sources/COpenCombineHelpers`.
3. **`Symbols` and `DeveloperToolsSupport` became shims** transcribed from Apple's interfaces.
   Their types are only referenced by SwiftUI's declarations, so identity is all that is needed.
4. **The engine dispatches primitives existentially** (`_PortRenderable`) instead of relying on
   `View._makeView` witness tables, whose storage lives in Apple's binary. Adding a primitive is
   now a one-file change.
5. **Stored constants got real values**: alignments (`PortAlignment.swift`), `Edge.Set`,
   direction sets, `EdgeInsets`, and a body-override mechanism (`port-impl/bodies.txt`) for stubs
   that must stay declared — e.g. an `OptionSet`'s `init(rawValue:)`.

Run it:

```bash
./scripts/port/build-port-sdk.sh        # retarget interfaces + shims + vendored Combine
./scripts/dev.sh                        # Atlas: build, package, install, launch, screenshot
./scripts/gallery.sh                    # control gallery: the same, as its own app
./scripts/test.sh                       # 38 host tests over the engine
```

The ported path is now the **default** build: `import SwiftUI` resolves to Apple's retargeted
declarations plus this project's engine. `SWIFTUI_PORT_GENERATED=0` builds the older engine-level
demo instead, which remains useful as a reference for the engine on its own.

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
| OSS Swift 6.4.3 toolchain, official Swift SDK for Android, NDK r30 | working; every path resolved by `scripts/env.sh` | `./scripts/env.sh --check`, `swift build --swift-sdk swift-6.4.3-RELEASE_android --triple aarch64-unknown-linux-android28` → ELF aarch64 |
| Apple interface retargeting (`build-port-sdk.sh`) | `SwiftUICore`, `SwiftUI`, `Symbols`, `Combine` retarget clean | `build/port-sdk/gen/**` |
| Fidelity: a real SwiftUI app typechecks for Android | **0 errors** | `scripts/port/check-demo.sh`, `build/port-sdk/probe.log` |
| Platform shims | every module the interfaces need (`UIKit`, `CoreGraphics`, `QuartzCore`, `CoreText`, `Symbols`, `Spatial`, `os`/`OSLog`, `simd`, `Accessibility`, `FoundationShims`, …) | `port-shims/**` |
| Apple declarations → compilable source | 11,197 declarations, 4,018 types, 7,945 bodies injected, 1,793 printed bodies kept (703 `@inlinable` ones verbatim) | `Sources/SwiftUI/Generated/`, `build/port-sdk/injected-bodies.json` |
| Generated port in the app target | **default**; `SWIFTUI_PORT_GENERATED=0` selects the engine-only build | `Package.swift` |
| View-graph seams | 608 catalogued (`body` 301, `_makeView` 178, `_makeViewList` 87, `_viewListCount` 42); everything both demos touch is implemented | `Sources/SwiftUI/Adapters/**` |
| C JNI bridge (`AndroidBridge.c`) | complete: 10 JNI entry points, 22 drawing primitives, cached paints/typefaces, exception-safe | compiles for arm64 + x86_64 with `-Wall -Wextra` |
| Java host (`MainActivity`, `SwiftUIHostView`) | complete: edge-to-edge, insets, gestures, back, config survival, transparent IME overlay | APK validated with `apksigner`/`zipalign` |
| APK pipeline (`build-apk.sh`) | complete: aapt2 → javac → d8 → zip → zipalign → sign, bundles the Swift runtime dylibs `llvm-readelf` reports as NEEDED | `build/SwiftUI-Android.apk` (~31 MB) |
| Emulator harness (`emulator.sh`, `device-test.sh`) | complete: headless API 35 arm64, install → launch → screenshot → crash/ANR assertions | `build/screenshots/**` |
| Engine: layout, scroll, hit test, display list, painter | complete, exercised by both demos | `Sources/SwiftUI/Engine/**`, `docs/DEMO.md` |
| Host tests | 38, green | `./scripts/test.sh` |
| Demo apps | Atlas (`dev.swiftui.android`) and the control gallery (`dev.swiftui.android.gallery`) both run on the emulator | `scripts/dev.sh`, `scripts/gallery.sh`, `docs/screenshots/**` |
| Controls, styles, text input, links | implemented; remaining gaps listed in `docs/GALLERY.md` | `Adapters/PortControls.swift`, `PortStyles.swift`, `PortTextInput.swift`, `PortLinkOpener.swift` |

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

## Two compiler-level discoveries worth recording

Both were found by trying to compile Apple's interface back from text, and both are genuine
Swift 6.4.3 behaviour, not port bugs:

1. **`$`-prefixed declarations are illegal in source and crash the frontend.** Apple's interface
   lists a property's projected value explicitly (`public var $isOn: Binding<Bool> { get }`).
   Declared literally, the compiler first rejects the name, and once the wrapper is present it
   segfaults in `PropertyWrapperAuxiliaryVariablesRequest`. The projection is synthesized from
   the wrapped property anyway, so the declaration is dropped
   (`scripts/port/strip_projected_vars.py`).

The generated declaration module now compiles for Android with **0 errors**
(`SWIFTUI_PORT_GENERATED=1 swift build … --product SwiftUIAndroidApp`).
2. **A property-wrapper attribute on a declaration that spells out its own accessors is
   malformed** — interfaces emit exactly that shape (`@Binding public var isOn: Bool { get }`).
   The port drops the attribute and supplies wrapper semantics in the engine.

## Known semantic gaps (by construction, not by accident)

| Gap | Why |
|---|---|
| No ObjC interop | Android has no ObjC runtime; `@objc` attributes are stripped when retargeting. UIKit-facing API is declarative only. |
| No Metal / CoreAnimation | rendering goes through `android.graphics.Canvas` (Skia, hardware accelerated), not CA::Render. |
| No CoreText | text shaping uses Android's `Paint`/`Typeface` (HarfBuzz under the hood) through the bridge. |
| No UIKit | `UIView`/`UIColor`/`UIImage` are declaration-faithful shims; bridging an actual `UIView` into the tree is impossible on Android. |
| Foundation must be dynamic | the Android SDK ships Foundation as dylibs (~74 MB bundled), so APK size is dominated by the Swift/Foundation runtime, not the port. |
| Three conformance clauses omitted | `Optional`/`_ConditionalContent`: `SliderTickContent` and `GestureStateGesture`: `Gesture` require associated-type witnesses that contradict the same type's `View`/`TabContent` witnesses; Apple relies on per-module witness shadowing, which one module cannot express. Only the clause is omitted; every omission is recorded in `injected-bodies.json` (`incompatible_conformances_omitted`) and `docs/PORT-BODIES.md` R14. |

## Reproduce

```bash
./scripts/port/build-port-sdk.sh          # retarget Apple interfaces + fidelity probe
./scripts/dev.sh                          # cross-compile → APK → install → screenshot
swift test                                # host-side engine tests
```
