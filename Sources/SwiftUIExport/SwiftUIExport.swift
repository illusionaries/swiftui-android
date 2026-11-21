// SwiftUI — the module applications import.
//
// Apple ships two modules: `SwiftUICore` (View, modifiers, property wrappers, the rendering
// primitives) and `SwiftUI` (controls and higher-level views built on it). The port compiles both
// interfaces into one module, which it names `SwiftUICore` to match how Apple's own macros expand
// (`SwiftUICore.State(…)`, `SwiftUICore.Binding(…)`).
//
// This module is the `SwiftUI` half: it re-exports everything, so `import SwiftUI` sees the whole
// framework exactly as an iOS app does, and macro expansions resolve without extra imports.
@_exported import SwiftUICore
