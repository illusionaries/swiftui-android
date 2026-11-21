# PORT-BODIES.md — how Apple's SwiftUI declarations become compilable port source

This document describes the **source-generation half** of the port: how
`Sources/SwiftUI/Generated/{SwiftUICore,SwiftUI}.swift` are produced from the retargeted
`.swiftinterface` files of Apple's SwiftUI framework, which mechanical rewrites are applied and
why, how the engine takes over individual declarations, and what is still unimplemented.

The **engine half** lives in `Sources/SwiftUI/Engine/` (layout, display list, scene seam,
`PortRuntime.swift`). `docs/PORT-SDK.md` describes the retargeting of the interface files
themselves; this document starts where that one ends.

---

## 1. Pipeline

```
Apple iOS Simulator SDK                  build/port-sdk/gen/<Module>.swiftmodule/*.swiftinterface
  SwiftUI.swiftinterface        ── retarget (build-port-sdk.sh, retarget_interface.py) ──┐
  SwiftUICore.swiftinterface  ────────────────────────────────────────────────────────────┤
                                                                                         ▼
                                     scripts/port/inject_bodies.py
                                   │  declarations preserved byte-for-byte
                                   │  + placeholder bodies for bodyless members
                                   │  + documented rewrites R1–R9
                                   ▼
        Sources/SwiftUI/Generated/SwiftUICore.swift   (compiled into module SwiftUI)
        Sources/SwiftUI/Generated/SwiftUI.swift       (compiled into module SwiftUI)
        build/port-sdk/injected-bodies.json           (machine-readable coverage manifest)
```

Regenerate with:

```sh
scripts/port/generate.sh            # regenerate + cross-compile check
scripts/port/generate.sh --check    # fail if the generated files are stale (CI)
scripts/port/generate.sh --no-build # regenerate only
```

The generated files are committed and **deterministic**: same interface + same script = same
bytes. Never edit them by hand; edit the generator (or the override file) and regenerate.

Prerequisites: `scripts/port/build-port-sdk.sh` has produced `build/port-sdk/gen/` and
`build/port-sdk/shims/`.

## 2. Module layout: one module named `SwiftUI`

Apple ships two modules (`SwiftUI`, `SwiftUICore`). The port compiles **one** module named
`SwiftUI` (`Package.swift` has a single `SwiftUI` target) containing both generated files plus
the engine. Consequences, handled by rule R1:

* `SwiftUICore::Foo` / `SwiftUICore.Foo` type references are rewritten to `Foo`;
* `@_exported import SwiftUICore` is dropped;
* `import SwiftUI` in application code gives exactly Apple's surface, as on iOS.

No type is declared in both interfaces (the generator checks and refuses to proceed otherwise),
so the merged namespace is unambiguous.

## 3. Declaration text is sacred

Every declaration Apple prints is reproduced **byte-for-byte** in the generated files: names,
generic parameters and constraints, attributes, availability annotations, parameter labels,
`@inlinable` bodies. The generator only *adds* bodies (and applies the explicitly documented
rewrites below). This is what makes the port's API Apple's API instead of an approximation.

What is added for a bodyless declaration:

| Apple interface spelling | generated source |
| --- | --- |
| `public func f(a: A) -> B` | `public func f(a: A) -> B { _suiUnimplemented("Module.T.f(a:)") }` |
| `public init(x: X)` | `public init(x: X) { _suiUnimplemented("Module.T.init(x:)") }` |
| `public subscript(i: I) -> V { get set }` | `public subscript(i: I) -> V { get { … } set { … } }` |
| `public var v: V { get }` | `public var v: V { get { _suiUnimplemented("Module.T.v") } }` |
| `public var v: V { get set _modify }` | one stub body per accessor |
| `@usableFromInline deinit` | `deinit {}` |
| `func f()` inside `protocol P` | unchanged — protocol requirements have no body |

`_suiUnimplemented` is defined once, in `Sources/SwiftUI/Engine/PortRuntime.swift`, and returns
`Never`, so a stub body also satisfies definite-initialisation in initializers and accessors:
the compiler knows the body never returns.

`@inlinable` bodies are Apple's own shipped code and are **never touched**. They already contain
real logic; where they call stubbed entry points, those calls are replaced at engine-implementation
time via the override mechanism.

Bodies are injected only into the *actively compiled* branch of `#if` blocks (rule R4); dead
fallback branches are kept verbatim.

## 4. Rewrite rules (the only changes to declaration text)

Each rule is also listed in the banner of every generated file. Rules are mechanical: they are
applied by pattern, not by hand, and never delete API (except R5/R6, which are explicit,
recorded omissions).

### R1 — module requalification (`SwiftUICore::Foo` → `SwiftUI.Foo`, duplicates dropped)

**Apple construct:** textual interfaces spell cross-module references with `::`
(`SwiftUICore::EnvironmentValues`) or a dot (`SwiftUICore.View`), and SwiftUI re-exports
SwiftUICore via `@_exported import SwiftUICore`.
**Why:** both interfaces compile into one module here, so those names are local. A Swift source
file cannot import a module that does not exist, and `Module::Name` on the module being compiled
would resolve to the prebuilt *Apple* interface, creating two distinct `View` types.

The qualifier is **rewritten to the compiled module name, not stripped**: dropping it lets a
generic parameter or a nested type shadow the intended type (`extension MenuBarExtra where
Label == Label<Text, Image>` then resolves `Label` to the generic parameter and fails with
"cannot specialize non-generic type 'Label'"). The printer also writes *nested* module
qualifiers (`SwiftUICore::SystemFormatStyle.SwiftUICore::DateReference`); there the second
qualifier is a lookup aid and is dropped (`SwiftUI.SystemFormatStyle.DateReference`), because
renaming it would produce the invalid `SwiftUI::SystemFormatStyle.SwiftUI::DateReference`.
**Count:** ~24–25 k requalifications per generation (see `self_qualifiers_removed` in the
manifest).

### R2 — interface-only stored properties become computed (`static let x: T` → `static var x: T { get { … } }`)

**Apple construct:**
```swift
@frozen public struct EventModifiers : Swift.OptionSet {
  public static let capsLock: SwiftUICore.EventModifiers     // no initializer in the interface
  public let rawValue: Swift.Int                             // instance storage: fine
}
```
**Why:** an interface describes storage that lives in Apple's binary. As source,
`static let x: T` without an initializer is rejected ("`static let` declaration requires an
initializer expression or an explicitly stated getter"). The port has no value to store, so the
declaration becomes a read-only computed property with an injected getter. `let` becomes `var`
because Swift has no computed `let`; both are read-only from the outside, so the public API is
unchanged. Stored properties declared in *extensions* are converted the same way (extensions
cannot add storage).

### R3 — opaque result types that cannot be expressed as source (`some P` → `Swift.Never`)

**Apple construct:** interfaces spell opaque results in three ways:
```swift
public var body: some SwiftUICore.View { get }                               // opaque result
public typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4LinkV4bodyQrvp", 0) __<Label>
```
**Why:** `@_opaqueReturnTypeOf` names an opaque type by the mangled name of Apple's binary
symbol; it only resolves when Apple's binary module is loaded, never in source. Likewise a
bodyless `var body: some View` cannot infer an underlying type (`some` requires a return
statement), and when the type also declares `typealias Body`, the witness must have that
concrete type.

The port replaces those with `Swift.Never` — the bottom type — whenever the declaration has no
body and the protocol has an `extension Never : P` (Apple declares those itself for `View`,
`Scene`, `Shape`, `Gesture`, …). A stub body returning `Never` then infers `Never` as the opaque
underlying type, so the declaration compiles and the conformance holds. If the protocol has no
`Never` conformance, the result type itself is rewritten to `Swift.Never`, which needs none.
A declaration that already has an `@inlinable` body is **never** rewritten (it has a real
opaque type of its own).

### R4 — Apple-compiler `#if` feature conditions are evaluated, dead branches are not injected into

**Apple construct:** the interfaces contain 800+ conditional regions of exactly three shapes:
```swift
#if compiler(>=5.3) && $TildeSendable
… declarations with `~Swift.Sendable` …
#else
… the same declarations without it …
#endif
```
(`$TildeSendable`, `$InlineAlways`, `$AsyncExecutionBehaviorAttributes`).
**Why:** these conditions ask whether the *compiling* optimizer supports a spelling; Swift 6.4.3
defines all three, so the `#if` branch is the live one (verified by `generate.sh`). The generator
evaluates them (any unknown condition is a hard error), injects bodies only into the live branch,
and keeps the dead branch byte-for-byte. That way the file still shows everything Apple declares
while never injecting a body that the compiler does not need.

### R5 — `$`-prefixed projected values are omitted

**Apple construct:** `public var $selection: SwiftUICore.Binding<Foundation.Date> { get }` (and
friends) — the projected value of a property-wrapper member, with the wrapper attribute spelled
out (`@SwiftUICore.Binding @_projectedValueProperty($isOn) public var isOn: Bool`).
**Why:** `$` is reserved for implicitly synthesised declarations: source cannot declare
`var $selection` ("cannot declare entity named '$selection'; the '$' prefix is reserved for
implicitly-synthesized declarations"). The projection exists in Apple's binary because the
wrapper is part of the ABI, but on the port the wrapper projection is synthesised by Swift from
the wrapped property — and the port does not use Apple's wrappers. The omission is recorded in
the manifest (`synthesized_projections_omitted`) and commented in the output.

### R6 — engine overrides: `port-impl/implemented.txt`

See section 6. Omitted declarations are the only other intentional omission.

### R7 — synthesised conformance witnesses for requirements Apple implements `internal`

**Apple construct:** a `.swiftinterface` prints only `public`, `package` and
`@usableFromInline internal` members. Many conformance witnesses in Apple's source are plain
`internal`, so they are absent even though the type conforms, e.g.:

```swift
@frozen public struct ZStack<Content> : View where Content : View { … }
// no `body` printed: in Apple's source it is `internal var body: Never`
@frozen public struct ZStackLayout : Layout { … }
// no `sizeThatFits(proposal:subviews:cache:)` printed: internal in Apple's source
```

**Why:** compiled as source, the type no longer conforms (`protocol requires property 'body' with
type 'ZStack.Body' (aka 'Never')`, `protocol requires function 'sizeThatFits(proposal:subviews:cache:)' …`).
The generator indexes the protocols declared in *both* interfaces (requirements, inheritance,
protocol-extension default implementations) and the members every type already has in
declarations *and* extensions, then copies each missing requirement out of the protocol
declaration and emits it with an injected body:

```swift
// port: synthesized witness for View (R7); Apple implements it with an internal member
public var body: Never { get { _suiUnimplemented("SwiftUI.ToggleStyleConfiguration.Label.body") } }
```

`Self.X` in the requirement is substituted by the type's own `typealias X` or the protocol's
associated-type default; an unknown associated type becomes `Swift.Never`.

An opaque result that carries generic arguments (`some TabContent<TabValue>`,
`some Gesture<Value>`, `some AttributedTextFormattingDefinition<Scope>`) is declared `Self`
when the declaration lives in a type or protocol extension: `Never` would have to satisfy the
primary-associated-type equality (`Never.TabValue == Self.TabValue`), while `Self` satisfies it
by construction, and `Never` converts to `Self`. Witnesses are emitted
`public` because outside library evolution Swift requires the witness of a public protocol to be
public. Requirement kinds the generator cannot spell (e.g. exotic accessor sets) are reported in
the manifest under `unsupported_requirements` instead of being silently skipped.

### R8 — property-wrapper attribute spellings are removed

**Apple construct:** `@SwiftUICore.Binding @_projectedValueProperty($isOn) public var isOn: Bool`.
**Why:** in source that attribute makes the compiler synthesise property-wrapper storage by
querying the wrapper type. The port's generated wrapper types are scaffolds (their wrapper
machinery is stubbed), and the compiler recurses through them
(`PropertyWrapperBackingPropertyTypeRequest` → stack overflow). The port does not use Apple's
wrappers — the `$` projection is omitted by R5 anyway — so the attribute is removed and the
declaration keeps the wrapped-value type Apple printed. Attributes are only removed when their
name is a `@propertyWrapper` type declared in either interface (plus
`@_projectedValueProperty`).

### R9 — initializers in extensions of classes become `convenience init`

**Apple construct:** `extension UIKit.UISceneSessionActivationRequest { public init?<D>(hostingDelegateClass: D.Type) … }`.
**Why:** Apple's interface can declare a designated initializer in an extension of an
Objective-C class (ObjC interop allows it). On the port that class is a plain Swift class in the
shim, and Swift rejects designated initializers in extensions. The generator looks the extended
type up in `port-shims/**/*.swift`; if it is a `class`, the initializer is emitted as
`convenience init` (its stub body never returns, so no delegation is required). Value types are
untouched.

### R10 — duplicate conformance witnesses from Apple's two interfaces are unified

**Apple construct:** the same type declares different witnesses for the same associated type in
each module. `ForEach` has `typealias Body = Never` for `View` in SwiftUICore and
`typealias Body = ForEach<...>` for `TabContent` in SwiftUI; the `body` properties follow the
same split (`Optional`, `Group`, `_ConditionalContent`, `ForEach` are the main cases).
**Why:** cross-module, Swift resolves each conformance against its own module's witness. In one
module there is exactly one witness per associated type ("invalid redeclaration of 'Body'",
"duplicate protocol requirement 'body'"), and a witness declared in a `where`-constrained
extension is invisible to a conformance declared under different constraints (`extension
ForEach : View where Content : View` cannot see a `Body` declared by `extension ForEach :
TabContent`). No conditional spelling can serve every conformance.

The port therefore keeps exactly one **unconditional** witness, emitted into the type's own
declaration (or one unconditional extension for a foreign type such as `Optional`):

* `typealias Body = Self` and `var body: Self { get { … } }` when the type's two halves disagree.
  `Self` satisfies every `Body: P` constraint of the type's own conformances and makes
  `Self.TabValue == Self.Body.TabValue` hold, so `TabContent`/`SliderTickContent`/`ToolbarContent`
  and friends all agree on one witness. `Never` would violate those primary-associated-type
  equalities.
* When the declared witness is a concrete type and a computed `body` has a different type, the
  mismatching `body` is omitted and a matching stub declared instead.
* A stored `body` property is never dropped (Apple's `@inlinable` initializers assign it), so
  `GestureStateGesture` keeps its public `body: (Value, inout State, inout Transaction) -> Void`
  closure and its `Gesture` conformance remains a reported gap.
* `Never`-conformances synthesised to support the old `Body = Never` unification (an earlier R12)
  were removed: `Never` cannot satisfy constrained associated types (`Scope: AttributeScope`), and
  `Body = Self` made them unnecessary.

Omitting a duplicate witness does not delete API: the associated type and the `body` requirement
keep exactly one declaration each, and the manifest lists every omission
(`duplicate_witnesses_omitted`).

### R11 — one public parameterless initializer per value type

**Apple construct:** Apple's `Spring` prints only `init(duration:bounce:)` (both parameters have
defaults) yet its own interface uses `Spring()` in a default argument; `AttributedTextSelection`
prints `init()` in an extension although the type has no stored properties.
**Why:** a struct with no stored properties gets an *implicit internal* `init()`, which public
default arguments cannot call (`initializer 'init()' is internal and cannot be referenced from a
default argument value`), while a second `init()` in an extension is an
`invalid redeclaration of synthesized 'init()'`; a class with stored properties and no
initializers is `class 'X' has no initializers`.

The generator therefore declares one `public init()` stub inside the type's own declaration when
a value type has no stored properties and no parameterless initializer, and omits any
parameterless `init()` in an extension of such a type. Classes with stored properties and no
initializers get the same stub (with `override` when the superclass declares `init()`).

### R13 — result-builder attributes are removed from stubbed declarations

**Apple construct:** `@TabContentBuilder<Self.TabValue> var body: Self.Body { get }`,
`@ViewBuilder var body: Self.Body { get }`, `@KeyframesBuilder<Value>` parameters.
**Why:** a result-builder attribute on a *protocol requirement* is applied to each witness's
body. The injected stub is `_suiUnimplemented(...)`, whose type is `Never`, so the builder
transform requires `Never` to satisfy the builder's generic constraints (`Never.TabValue ==
Self.TabValue`, `Never.Scope == Scope`) and the declaration fails to type-check
("static method 'buildExpression' requires that 'Never' conform to 'TabContent'"). The attribute
is a client-side convenience: without it the signature and every call site are unchanged, so it
is removed from declarations that receive a stub body (and from protocol requirements), and
never from Apple's `@inlinable` bodies.

### R14 — three conformance clauses are omitted (recorded single-module conflicts)

Apple splits each type's conformance witnesses between its `SwiftUI` and `SwiftUICore` modules, so
each conformance can use its own module's associated-type witness. A single module has exactly one
witness per associated type, and three conformances require witnesses that are mutually
incompatible with the type's other conformances:

| Type | Protocol | Conflicting witness | Recorded in |
|---|---|---|---|
| `Optional` | `SliderTickContent` | `Body: RandomAccessCollection` with `Body.Element == SliderTick<Self.Value>` vs `Body: View` (from `View`) and `Body: TabContent` (from `TabContent`) | manifest `incompatible_conformances_omitted` |
| `_ConditionalContent` | `SliderTickContent` | the same conflict; the shipped `SliderTickContent` half is also internally inconsistent (`typealias Body = TrueContent` but `body: TrueContent.Body`) | manifest `incompatible_conformances_omitted` |
| `GestureStateGesture` | `Gesture` | the public **stored** `body: (Value, inout State, inout Transaction) -> Void` property shadows `Gesture`'s requirement `body: Self.Body` (`Never`), and the stored property cannot be dropped because Apple's `@inlinable init` assigns it | manifest `incompatible_conformances_omitted` |

Only the conformance **clause** is removed (the extension keeps its members, the struct keeps its
other conformances); no other declaration is touched. Each omission is emitted as a grep-able
marker comment at the site

```swift
// port: omitted conformance <Type>: <Protocol> — single-module witness conflict (see PORT-BODIES.md)
```

counted in `stats.incompatible_conformances_omitted`, and recorded in the manifest with type,
protocol, declaring module and the exact conflicting-witness reason. `docs/PORT-STATUS.md` mirrors
the table under "semantic gaps".

### R15 — SE-0293 init accessors initialize their storage

**Apple construct:** a property with an init accessor, e.g.
`@storageRestrictions(initializes: _value) init(initialValue)` (used by layout modifiers such as
`_GeometryActionModifier2.value`).
**Why:** Swift's definite-initialization pass requires an init accessor to initialize every
storage property named by `@storageRestrictions(initializes:)`; a `Never`-returning stub is
rejected ("property '_value' not initialized by init accessor"). The injected body copies the
initial value into the storage and then reports the unimplemented accessor.

## 5. Symbol spelling (used by the manifest and by `port-impl/implemented.txt`)

```
<Apple module>.<Type path>.<member>(<external labels, each with ':'>)
```

* module: `SwiftUICore` or `SwiftUI` — where Apple declared it, even though both compile into
  module `SwiftUI`;
* type path: module qualifiers and generic arguments dropped (`SwiftUICore.ForEach.body`);
* members with labels: `SwiftUICore.Text.font(_:)`, `SwiftUI.VStack._makeView(view:inputs:)`,
  `SwiftUICore.ForEach.init(_:content:)`, `SwiftUICore.Text.subscript(dynamicMember:)`;
* properties: no labels (`SwiftUICore.Text.body`, `SwiftUI.Link.body`).

## 6. Engine overrides (`port-impl/implemented.txt`)

The generated module is a scaffold; the engine replaces the entry points it implements. Put one
symbol per line in `port-impl/implemented.txt` (`#` comments and blank lines allowed), and the
generator **omits that declaration** from the generated output so the engine can declare it with
a real body in an extension in the same module:

```swift
// port-impl/implemented.txt
SwiftUICore.Text.body
SwiftUICore.Text.font(_:)
SwiftUI.VStack._makeView(view:inputs:)
```

```swift
// Sources/SwiftUI/Engine/Implemented/Text.swift
extension Text {
    public var body: some View { … }                       // witness in an extension is legal
    public func font(_ font: Font?) -> Text { … }
}
```

Details:

* overriding a **stub** means the declaration moves out of the generated file; it is not a
  redeclaration (the generated one is gone);
* if the omitted symbol is an **opaque witness** (`var body: some View`), the generator also
  omits that type's `@_opaqueReturnTypeOf` associated-type spelling, so Swift infers `Body` from
  the engine's witness instead of pinning it to `Never`;
* a **stored instance property** cannot be overridden — extensions cannot add storage — and the
  generator refuses with an explicit error; the same applies to **class designated
  initializers** (Swift requires them in the class body);
* every symbol must match a bodyless declaration; unknown symbols are a hard error so typos do
  not silently do nothing;
* a missing override file means "nothing overridden";
* `generate.sh --check` fails when the generated files are stale, so commit the regenerated
  output together with the override file.

## 7. Manifest: `build/port-sdk/injected-bodies.json`

```jsonc
{
  "schema": 1,
  "target": "aarch64-unknown-linux-android28",
  "compiled_module": "SwiftUI",
  "layout": "single-module: …",
  "files": { "SwiftUICore.swift": "SwiftUICore", "SwiftUI.swift": "SwiftUI" },
  "modules": { "SwiftUICore": { …per-file counts… }, "SwiftUI": { … } },
  "stats": { …sums… },
  "seams": {
    "body":                     {"count": N, "symbols": ["SwiftUICore.Text.body", …]},
    "_makeView(view:inputs:)":   {"count": N, "symbols": [ … ]},
    "_makeViewList(view:inputs:)": {"count": N, "symbols": [ … ]},
    "_viewListCount(inputs:)":   {"count": N, "symbols": [ … ]},
    "total": N
  },
  "overridden": {"count": N, "symbols": [ … ]},
  "synthesized_projections_omitted": {"count": N, "symbols": [ … ]},
  "synthesized_witnesses": {"count": N},
  "unsupported_requirements": {"count": N, "symbols": [ … ]},
  "incompatible_conformances_omitted": {
    "count": 3,
    "entries": [
      {"type": "Optional", "protocol": "SliderTickContent", "declared_in": "SwiftUI",
       "compiled_in": "SwiftUI", "conflicting_witness": "Body: RandomAccessCollection … vs Body: View"}
    ]
  },
  "bodies": [
    {"symbol": "SwiftUICore.LayoutDirection.hash(into:)", "module": "SwiftUICore",
     "kind": "func", "inlined": false},
    {"symbol": "SwiftUICore.View.disabled(_:)", "module": "SwiftUICore",
     "kind": "func", "inlined": true}
  ]
}
```

* `inlined: false` — the body is a placeholder that traps at runtime and reports the symbol; this
  is the work list for the engine (and `PortDiagnostics` records hits at runtime, which the test
  harness uses to assert coverage of a rendered screen).
* `inlined: true` — Apple shipped an `@inlinable` body; it is real Apple code (it may still call
  stubbed entry points, but its own logic is Apple's).
* `seams` is the list the engine is written against: every `body`, `_makeView(view:inputs:)`,
  `_makeViewList(view:inputs:)` and `_viewListCount(inputs:)`, including synthesised witnesses.
* `incompatible_conformances_omitted` is the audit trail for R14: every omitted conformance
  clause with its exact reason. Nothing is dropped silently.

`kind` is `func`, `var`, `init`, `subscript` (and `deinit` for destructors).

## 8. Build / verify

`scripts/port/generate.sh` runs the generator and then type-checks the generated module against
the Port SDK:

```sh
export PATH=$SWIFT_TOOLCHAIN/usr/bin:$PATH
scripts/port/generate.sh
```

The equivalent raw command (also what the acceptance gate uses, plus the engine seam):

```sh
swiftc -typecheck -parse-as-library \
  Sources/SwiftUI/Generated/SwiftUICore.swift Sources/SwiftUI/Generated/SwiftUI.swift \
  Sources/SwiftUI/Engine/PortRuntime.swift \
  -module-name SwiftUI -target aarch64-unknown-linux-android28 \
  -resource-dir ~/Library/org.swift.swiftpm/swift-sdks/swift-6.4.3-RELEASE_android.artifactbundle/swift-android/swift-resources/usr/lib/swift-aarch64 \
  -sdk ~/Library/org.swift.swiftpm/swift-sdks/swift-6.4.3-RELEASE_android.artifactbundle/swift-android/ndk-sysroot \
  -I build/port-sdk/gen -I build/port-sdk/shims \
  -swift-version 5 -enable-experimental-feature AnyAppleOSAvailability \
  -package-name SwiftUI -module-cache-path build/port-sdk/.module-cache-bodies
```

The real integration build is the package build the lead wired up:

```sh
swift build -c release --product SwiftUIAndroidApp \
  --swift-sdk swift-6.4.3-RELEASE_android --triple aarch64-unknown-linux-android28
```

`generate.sh` classifies diagnostics: errors whose file is under `Sources/SwiftUI/Generated/`
are generator bugs and fail the run; everything else is attributed to the Port SDK (missing or
incomplete shims) and reported separately.

## 9. Current coverage (regenerate for exact numbers)

The generator prints counts; `--check`/`generate.sh` keeps them honest. A representative
generation of the pinned toolchain:

* 11,197 declarations reproduced, 4,018 types;
* 8,102 stub bodies injected (functions, initializers, subscripts, accessors, deinit);
* 1,797 bodies kept as printed, of which 704 are Apple's `@inlinable` bodies (never modified);
* 108 opaque-result rewrites (R3), 669 static-storage rewrites (R2), 384 synthesised
  witnesses (R7), 35 duplicate-witness omissions (R10), 646 synthesised initializers (R11),
  25,437 module requalifications (R1), 3 omitted conformance clauses (R14);
* engine seams: 178 `_makeView(view:inputs:)`, 87 `_makeViewList(view:inputs:)`,
  42 `_viewListCount(inputs:)`, 304 `body` (611 total; the manifest lists them all);
* **the package gate is green**: `SWIFTUI_PORT_GENERATED=1 swift build -c release
  --product SwiftUIAndroidApp --swift-sdk swift-6.4.3-RELEASE_android` succeeds with 0 errors.

## 10. Known gaps outside this generator (report, do not work around)

These are tracked by the Port SDK / engine workstreams. They show up as diagnostics that point
into the generated files but are *caused* by the Port SDK:

* **Shim API gaps.** Missing declarations in `port-shims/*` surface as `cannot find type …`,
  `no type named X in module 'CoreData'`, `type 'String.StandardComparator' has no member
  'localizedStandard'` (Android Foundation is older than Darwin's),
  `overriding non-open property outside of its defining module`, `method does not override any
  method from its superclass` (shim base classes missing members that Apple's interface
  overrides), and `Never` lacking conformances that Apple's binary modules declare
  (`extension Never : Transferable` from CoreTransferable, etc.).
* **Retarget drops a few declarations from the interfaces.** Example seen in this cycle:
  `SwiftUICore`'s `Text.init(_:tableName:bundle:comment:)` (`@_semantics("swiftui.init_with_localization")`)
  exists in Apple's shipped interface but is absent from the retargeted one; inlinable bodies in
  the same interface call it, producing `initializer 'init(_:)' requires that
  'LocalizedStringKey' conform to 'StringProtocol'`. The fix belongs in `retarget_interface.py`
  (never delete a declaration); the generator will pick it up automatically.
* **Do not put the port's own prebuilt interfaces on the compile include path.** `build/port-sdk/gen`
  contains retargeted `SwiftUI.swiftmodule` and `SwiftUICore.swiftmodule` *interfaces*, and the
  module being compiled is also named `SwiftUI` (and contains the SwiftUICore declarations). With
  `-I build/port-sdk/gen` the compiler loads those interfaces as modules too and then reports
  hundreds of `ambiguous type name '…'`, `'X' is ambiguous for type lookup`, and `cannot
  specialize non-generic type 'Label'` diagnostics. `generate.sh` therefore stages
  `build/port-sdk/deps/` (symlinks to every Port SDK module *except* `SwiftUI`/`SwiftUICore`) and
  types against that. Package builds must do the same — or `build-port-sdk.sh` should write the
  `SwiftUI`/`SwiftUICore` interfaces into a separate directory used only by the app probe.
* **The UIKit shim imports SwiftUICore.** `port-shims/UIKit/UIKit.swift`
  (`public import SwiftUICore`) and its interface (`UITraitBridgedEnvironmentKey: SwiftUICore.EnvironmentKey`)
  require a module named `SwiftUICore`. In the single-module port there is no such module (the
  declarations are inside `SwiftUI`), so either the UIKit shim must drop that dependency (or
  declare the protocol without the conformance) or the port must keep a separate `SwiftUICore`
  module target. Until then the generated module cannot be compiled end-to-end against the real
  shims.
* **Engine type-name collisions.** The engine currently declares `FillStyle`
  (`Engine/Node.swift`) and `DragGesture` (`Engine/Interaction.swift`), which are also Apple
  declarations now present in the generated files; that is a same-module redeclaration and
  shows up as `'FillStyle' is ambiguous for type lookup`. Engine-internal types should be
  namespaced/prefixed (`PortFillStyle`, …) or renamed.
## 10.1 Status: the generated port compiles cleanly

As of this cycle the package gate is green: `SWIFTUI_PORT_GENERATED=1 swift build -c release
--product SwiftUIAndroidApp --swift-sdk swift-6.4.3-RELEASE_android` completes with **0 errors**
(155 warnings, all shim/availability/Sendable diagnostics that also exist in Apple's own
interface compile). The single-module port therefore reproduces all 11,197 Apple declarations;
the only losses are the three recorded conformance clauses (R14), and the external gaps listed
above belong to the Port SDK / retarget workstreams.

## 11. What the engine must implement first for a screen to render

The display-list/layout engine in `Sources/SwiftUI/Engine/` gets the app's view tree from these
seams, in dependency order (symbols are in the manifest; qualify them in
`port-impl/implemented.txt` as you implement them):

1. **View-graph plumbing**
   `Views._makeView(view:inputs:)`, `View._makeViewList(view:inputs:)`,
   `View._viewListCount(inputs:)`, and the value types they use:
   `_GraphValue`, `_ViewInputs`, `_ViewOutputs`, `_ViewListInputs`, `_ViewListOutputs`,
   `_ViewListCountInputs`, `_ViewDebug`.
2. **Result builders** — `ViewBuilder` (`buildBlock`, `buildExpression`, `buildIf`,
   `buildEither`, …) so `body` expressions compose; then the per-content builders
   (`ToolbarContentBuilder`, `TabContentBuilder`, …) can stay stubs until those features land.
3. **Primitive views**: `Text._makeView` + `Text.body`, `Color._makeView` + `Color.body`,
   `Spacer`, `Image`, `Shape`/`Rectangle`, and the `AnyView` eraser.
4. **Stacks**: `VStack`/`HStack`/`ZStack` `_makeView` (plus their `_ZStackLayout`/`_VStackLayout`
   `Layout.sizeThatFits(proposal:subviews:cache:)`/`placeSubviews(in:proposal:subviews:cache:)`).
5. **Modifiers that matter for a first screen**: `.padding`, `.frame`, `.font`,
   `.foregroundColor`, `.background`, and the `_EnvironmentKeyTransformModifier` /
   `_Trait` paths their inlinable bodies hit.

Everything else may stay `_suiUnimplemented` for a long time: a stub traps only when the screen
actually reaches it, and `PortDiagnostics.unimplementedHits` records exactly which symbols a
render touched — that list is the engine's work queue.
