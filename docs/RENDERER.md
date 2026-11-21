# Renderer adapters — how Apple's declarations become pixels

Apple's `SwiftUI` interface compiles for Android (`scripts/port/build-port-sdk.sh`). The layer that
turns a `View` value into pixels is `Sources/SwiftUI/Adapters/`. Both demo apps run on it, and this
document is how it works and what it covers.

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

608 such entry points are catalogued in `build/port-sdk/injected-bodies.json` (`body` 301,
`_makeView` 178, `_makeViewList` 87, `_viewListCount` 42). Each is a *function*, so
`port-impl/implemented.txt` omits the generated stub and an extension in `Engine/` or `Adapters/`
(same module) supplies the real one. Anything not overridden keeps the generated
`_suiUnimplemented("Type.symbol")` body, which traps and names itself — a missing piece announces
itself instead of silently drawing nothing.

## Why the adapters need a context

`_GraphValue`, `_ViewInputs`, `_ViewOutputs`, `_ViewListInputs`, `_ViewListOutputs` are **opaque**
in Apple's interface — their storage lives in Apple's binary, so recompiled from text they are
empty structs. That is not a problem, because Apple's own engine is context-driven too: the graph
value is threaded through a `ViewGraph`, not through the structs.

So the port mirrors that shape:

```
PortRenderContext (per frame, thread-local)
  viewStack:   [Any]            // the value currently being made into a view
  outputStack: [LayoutNode]     // what each _makeView produced
  environment: EnvironmentValues subset (colorScheme, font, accentColor, displayScale, styles)
  proposal:    ProposedSize     // what the parent offers
```

`_makeView(view:inputs:)` implementations read their own value from the context, build a
`LayoutNode`, push it, and return an empty `_ViewOutputs()`; the caller pops it. The generated
declarations stay byte-identical to Apple's, and adding an adapter needs no generator change.

## Mapping table

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

## What the adapters cover

| File | Types it implements |
|---|---|
| `PortGraph.swift` | `View._makeView` default (evaluate `body`, recurse), the per-frame context, `PortEnvironment` |
| `PortPrimitives.swift` | `EmptyView`, `Spacer`, `TupleContent`, `TupleView`, `HStack`, `ModifiedContent`, `Optional`, `Text` plumbing |
| `PortText.swift` | `Text` storage, fonts, `LocalizedStringKey` interpolation |
| `PortStyle.swift`, `PortStyleRender.swift` | `Color`, `Font`, `Gradient`, `LinearGradient`, `Rectangle`, `Circle`, `Capsule`, `_ShapeView`, the style registry |
| `PortStyle`-side modifiers | `padding`, `frame`, `background`, `overlay`, `clipShape`, `shadow`, `opacity`, `offset`, `cornerRadius`, `foregroundStyle` |
| `PortAlignment.swift`, `PortGeometryStatics.swift` | `Alignment`, `HorizontalAlignment`/`VerticalAlignment`, `Edge.Set`, `EdgeInsets`, direction sets, `UnitPoint`, `PinnedScrollableViews` |
| `PortState.swift` | `State`, `Binding`, `LazyState` (what Apple's macro emits); the store keys them by wrapper creation order |
| `PortButton.swift` | `Button` (all title inits) and its style rendering |
| `PortWidgets.swift` | `Toggle` (switch and `.button`), `Group`, `_ConditionalContent`, `Image(systemName:)`, `StateObject`, `ObservedObject.Wrapper` |
| `PortControls.swift` | `Slider`, `Stepper`, `Picker`, `TextField`, `ProgressView`, `Label`, `Link` |
| `PortStyles.swift` | `.buttonStyle`/`.toggleStyle`/`.pickerStyle`/`.textFieldStyle` writing environment values; built-in style recognition |
| `PortLists.swift` | `ForEach`, `LazyVGrid`, `ScrollView` with the scroll store, `Divider`, `Axis.Set` |
| `PortTextInput.swift`, `PortLinkOpener.swift` | platform seams: the IME, URL opening |

## How it was built

1. `PortRenderContext` and the `View._makeView` default (evaluate `body`, recurse).
2. `Text`, `EmptyView`, `Spacer`, `TupleView`, `_ConditionalContent`, `Optional`, `Group`.
3. `VStack`/`HStack`/`ZStack` from their `_tree`, with the two `Layout` witnesses
   (`sizeThatFits(proposal:subviews:cache:)` and `placeSubviews(in:proposal:subviews:cache:)`)
   delegating to the engine's stack measurement.
4. `ModifiedContent` for padding/frame/background/overlay/shadow, then colour, shapes, `Button`,
   `ForEach` and `ScrollView`.
5. The control gallery added what a form needs: the eight controls, the built-in styles as
   environment values, drag handling for sliders and the scroll view, and the two platform seams
   (IME text input, `Link`).

Adapters compile in the default (ported) build. `SWIFTUI_PORT_GENERATED=0` excludes them together
with `Generated/`, which is how the engine-only build stays green on its own.

## Verify it

```bash
./scripts/port/check-demo.sh      # a real SwiftUI app typechecks against Apple's interface alone
./scripts/dev.sh                  # cross-compile → APK → install → launch → screenshot
./scripts/gallery.sh              # the control gallery, its own app id
./scripts/test.sh                 # 38 host tests over the engine
```

The device gate — install, launch, alive after launch, no crash or ANR, screenshot plus filtered
logcat — is `scripts/device-test.sh`, which both demo scripts call at the end.
