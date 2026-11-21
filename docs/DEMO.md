# Atlas — the demo application

A multi-screen product UI running on the port, on a real Android device. Not a renderer test:
it has navigation, scrolling, tabs, toggles, a grid, a detail feed and its own design system.

| | |
|---|---|
| **Home** | gradient hero card, "Continue reading" pair, 2×2 metric tiles, feed rows with gradient badges |
| **Discover** | search field, selectable category chips, two-column card grid with category overlays and save state |
| **Detail** | push/pop navigation, gradient header, article body, bullet highlights, like/save actions that mutate state |
| **Profile** | circular avatar, stat tiles, three switch rows, about card, reset action |

![Home](screenshots/atlas-home.png)
![Discover](screenshots/atlas-discover.png)

## How it is put together

```
AtlasScene  (Sources/DemoApp/AtlasScene.swift)
   state      Tab · detail id · liked/saved sets · toggles · scroll offset
   build()    state → LayoutNode tree (stacks, frames, fills, shapes, scroll, zstack)
   draw()     measure → place → paint → DisplayList
   input      hitTest(point) → node.action();  drag → ScrollModel
Theme       (DemoTheme.swift)  colours, gradients, type ramp, dark-mode derivation
Components  (AtlasScene.swift) cards, chips, badges, metric tiles, switch rows, tab bar
```

Every screen is a pure function of state — `build()` is re-run when state changes, exactly the
model the SwiftUI adapters will drive. The node vocabulary (`vstack`/`hstack`/`zstack`/`spacer`/
`padding`/`frame`/`background`/`overlay`/`cornerRadius`/`shadow`/`scroll`) maps one-to-one onto
the SwiftUI modifiers of the same name, so the demo is the fixture the ported `View` adapters
will be validated against.

## What the demo exercised (and fixed) in the engine

Building a real app shook out six bugs that a one-page test never would:

1. **Shadows inflated layout** — a shadowed card measured larger than its parent and overflowed.
   Fixed: shadows paint outside the layout box and never change the reported size (SwiftUI
   semantics), with an optional corner radius so they follow rounded shapes.
2. **Offsets inflated layout** — same class of bug, fixed the same way.
3. **`ZStack` was a vertical stack** — it had been modelled as `stack(axis: .vertical)`, so
   overlapping children were being laid out in sequence. Now a real overlay container.
4. **Gradient fills dropped corner radius** — every rounded card and avatar painted square.
5. **Text ignored frame alignment** — glyphs sat at the leading edge of centred boxes; text now
   honours its alignment within the measured frame.
6. **Protocol extension dispatch** — `handleDrag` was only defined in a `PortScene` extension, so
   it was statically dispatched and scrolling silently never reached the scene. It is a real
   protocol requirement now.

## Interaction proof

Scrolling, tab switching and push/pop are driven through the same `MotionEvent → JNI → Swift →
invalidate → repaint` path as any native app:

![Scrolled home](screenshots/atlas-home-scrolled.png)
