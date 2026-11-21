# Renderer adapters — how Apple's declarations become pixels

The Port SDK compiles Apple's `SwiftUI` interface for Android (`scripts/port/build-port-sdk.sh`,
probe: 0 errors). The engine (`Sources/SwiftUI/Engine/**`) already renders a complete app through
its own layout tree. This document specifies the last piece: the adapters that bind Apple's
declared types to that engine, so real SwiftUI source (`demos/AtlasSwiftUI.swift`) renders.

## The seam Apple exposes

```swift
public protocol View {
  nonisolated static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs
  nonisolated static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs
  nonisolated static func _viewListCount(inputs: _ViewListCountInputs) -> Int?
  associatedtype Body: View
  @ContentBuilder var body: Body { get }
}
```

594 such seams are catalogued in `build/port-sdk/injected-bodies.json` (`body` 304,
`_makeView` 178, `_makeViewList` 87, `_viewListCount` 42). Each is a *function*, so
`port-impl/implemented.txt` can omit the generated stub and an extension in `Engine/` (same
module) can supply the real one.

## Why the adapters need a context

`_GraphValue`, `_ViewInputs`, `_ViewOutputs`, `_ViewListInputs`, `_ViewListOutputs` are **opaque**
in Apple's interface — their storage lives in Apple's binary, so recompiled from text they are
empty structs. That is not a problem, because Apple's own engine is also context-driven: the graph
value is threaded through a `ViewGraph`, not through the structs.

So the port mirrors that shape:

```
PortRenderContext (per frame, thread-local)
  viewStack:   [Any]            // the value currently being made into a view
  outputStack: [LayoutNode]     // what each _makeView produced
  environment: EnvironmentValues subset (colorScheme, font, accentColor, displayScale)
  proposal:    ProposedSize     // what the parent offers
```

`_makeView(view:inputs:)` implementations read their own value from the context, build a
`LayoutNode`, push it, and return an empty `_ViewOutputs()`. The caller pops it. No generator
change is needed and the generated declarations stay byte-identical to Apple's.

## Mapping table (first vertical slice)

| Apple declaration | Read from | Produces |
|---|---|---|
| `Text` | `storage` (`.verbatim(String)`), `modifiers` (`font`, `color`, `weight`, `kerning`) | `.text(TextSpec)` |
| `VStack` | `_tree.root` (`_VStackLayout.alignment/spacing`), `_tree.content` | `.vstack` / `_VStackLayout.sizeThatFits` |
| `HStack` | `_tree.root` (`_HStackLayout`), `_tree.content` | `.hstack` |
| `ZStack` | `_tree.root` (`_ZStackLayout`), `_tree.content` | `.zstack` |
| `Spacer` | `minLength` | `.spacer` |
| `EmptyView` | — | `.empty` |
| `TupleView<T>` | `value` via `Mirror` + `_openExistential` | children list (one `_makeView` per element) |
| `_ConditionalContent<A,B>` | enum case | the taken branch only |
| `Optional<Wrapped>` | `.some`/`.none` | child or `.empty` |
| `Group<Content>` | `content` | flattened children |
| `ModifiedContent<C, _PaddingLayout>` | `modifier.insets ?? edges` | `.padding` |
| `ModifiedContent<C, _FrameLayout>` | `width/height/alignment` | `.frame` |
| `ModifiedContent<C, _BackgroundModifier>` | `background` content | `.background` |
| `ModifiedContent<C, _OverlayModifier>` | `overlay` content | `.overlay` |
| `ModifiedContent<C, _ShadowEffect>` | `radius/x/y/color` | `.shadow` |
| `Color` | `provider` (`AnyColorBox`) | `.fill(.color)` |
| `_ShapeView<S, Style>` | Apple's own inlinable body already routes through `Shape.path(in:)` | `.shape` |
| `Button<Label>` | label content + action storage | `.tap` node |

`ViewBuilder` is not on this list: Apple's `buildBlock`/`buildExpression`/`buildEither` bodies are
`@inlinable` and preserved verbatim in `Sources/SwiftUI/Generated/SwiftUICore.swift`, so tuple and
conditional content construction is Apple's own code.

## Order of work

1. `PortRenderContext` + `View._makeView` default (evaluate `body`, recurse).
2. `Text`, `EmptyView`, `Spacer`, `TupleView`, `_ConditionalContent`, `Optional`, `Group`.
3. `VStack`/`HStack`/`ZStack` (their internal `_tree`), then the two `Layout` witnesses
   (`sizeThatFits(proposal:subviews:cache:)` / `placeSubviews(in:proposal:subviews:cache:)`)
   which can delegate straight to the engine's stack measurement.
4. `ModifiedContent` for padding/frame/background/overlay/shadow.
5. `Color`, shape views, `Button`, `ForEach` + `ScrollView` list plumbing.

Each step lands in `Sources/SwiftUI/Adapters/`, which `Package.swift` excludes unless
`SWIFTUI_PORT_GENERATED=1`, so the repository keeps building throughout.

## Acceptance

```bash
# 1. Apple's declarations compile
SWIFTUI_PORT_GENERATED=1 swift build --product SwiftUIAndroidApp \
  --swift-sdk swift-6.4.3-RELEASE_android --triple aarch64-unknown-linux-android28

# 2. A real SwiftUI app typechecks against them (already true today)
./scripts/port/check-demo.sh

# 3. That same app renders on the device
adb install -r -t build/SwiftUI-Android.apk && adb shell am start -n dev.swiftui.android/.MainActivity
```

Step 3 is the finish line: `demos/AtlasSwiftUI.swift` moves into `Sources/DemoApp/` unchanged and
replaces the engine-level Atlas scene.
