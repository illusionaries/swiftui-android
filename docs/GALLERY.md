# The control gallery — the second demo app

`Sources/DemoApp/ControlGallery.swift` is a standalone app that exercises SwiftUI's controls
through the port. It ships as its own APK with its own application id
(`dev.swiftui.android.gallery`), next to the Atlas demo — two icons on the launcher, no switcher.

```bash
./scripts/gallery.sh                 # build, install, launch, screenshot
./scripts/gallery.sh --no-install    # only build build/SwiftUI-Gallery.apk
./scripts/build-apk.sh --demo gallery   # package an already-built library
```

![Control gallery](screenshots/gallery-top.png)

## Why a second app instead of a screen inside Atlas

The two demos test different things and would fight over one binary: Atlas is a four-screen app
that stresses navigation, scrolling and layout; the gallery is a dense page of interactive
controls that stresses bindings, gestures and text input. Keeping them apart also keeps each
demo's APK honest — what you install is one demo, with no dead code for the other.

The demo is selected at compile time (`SWIFTUI_DEMO_GALLERY=1` → `-DPORT_DEMO_GALLERY`), so
`SwiftUIHostScene` hosts `ControlGallery()` in one build and `AtlasRootView()` in the other.

## What the gallery demonstrates

Each control is Apple's declared type, rendered by this project's adapter and driven through its
`Binding`. The header prints live state (`40% · n=3 · mode=1 · Medium · "" · on=true · focus=no`),
so a screenshot after an interaction is evidence that the model changed, not just the pixels.

| Section | Apple API exercised | Variants shown |
|---|---|---|
| Buttons | `Button(_:action:)`, `Button(action:label:)` | filled, tinted, disabled, composed label with `Image` + `Text` |
| Toggles | `Toggle(_:isOn:)`, `.labelsHidden()` | labelled row, hidden label |
| Sliders | `Slider(value:)`, `Slider(value:in:step:)` | continuous, stepped (0.05) with end labels |
| Stepper | `Stepper(value:in:step:label:)` | bounded `0…10`, `−`/`+` group |
| Pickers | `Picker(_:selection:content:)`, `.tag(_:)` | `Int` tags, `String` tags — the same control with two selection types |
| Text field | `TextField(_:text:)` | placeholder at rest, focused field with caret + system IME |
| Progress | `ProgressView(value:)`, `ProgressView(value:label:currentValueLabel:)` | plain bar, labelled bar |
| Label / Link / Divider | `Label(_:systemImage:)`, `.labelsHidden()`, `Link(_:destination:)`, `Divider()` | icon + title, icon only, accent-coloured link, rule |
| Modifiers | `.padding`, `.background`, `.frame`, `.shadow`, `.overlay`, gradients, `.foregroundColor`, `.font` | rounded swatches at three radii, shadow, gradient, clipped capsule |

![Control gallery, lower half](screenshots/gallery-bottom.png)

## Text input is real: the platform IME edits SwiftUI state

A cursor, a selection and a soft keyboard cannot be drawn to a canvas, so the port hosts an
invisible Android `EditText` over the field and lets it own the IME session while SwiftUI keeps
owning the styling and the binding:

```
tap  → TextField adapter      → PortTextInput.beginEditing(slot:text:frame:onText:onEnd:)
     → SwiftUIAndroid         → JNI: the View polls nativeTextInputCommand
     → SwiftUIHostView        → transparent EditText over the field, IME opens
typing → TextWatcher          → nativeTextChanged*  (UTF-16, four units per jlong)
       → PortTextInput.hostTextChanged → binding → next frame draws the new text
```

`Sources/SwiftUI/Adapters/PortTextInput.swift` declares that seam; `SwiftUIAndroid` installs it
at startup, so the framework module never depends on the platform. Typing also asks for a frame
(`AndroidRuntime.invalidate`), because an edit arrives outside any draw.

![Typing into a ported TextField](screenshots/gallery-text-field.png)

## What is still missing (visible on purpose)

- **One style per control.** `ButtonStyle` / `ToggleStyle` / `PickerStyle` /
  `TextFieldStyle` are declared by Apple but their `_makeView`/`makeBody` members are still
  stubs, so `.pickerStyle(.segmented)` does not change anything: each control has exactly the one
  rendering the adapter chooses. Variants in the demo therefore come from composition with
  modifiers, not from style types.
- **`Link` paints but does not open.** Following a URL needs an Android `Intent`, which the
  bridge does not expose yet; the destination is kept, the action is missing.
- **SF Symbols are text glyphs.** `Image(systemName:)` maps a name onto the closest character
  (`★`, `♥`, `⌕`, …), so symbol-heavy layouts are approximations.
- **`Divider` orientation, `ProgressView()` (indeterminate) and `SecureField`** are not
  implemented yet; `Divider()` and the determinate progress forms are.
- **Focus does not always end with the IME.** Pressing BACK closes the keyboard but the session
  stays live (the field keeps its accent ring and caret) until another field is tapped.
