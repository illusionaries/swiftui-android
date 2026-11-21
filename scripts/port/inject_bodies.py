#!/usr/bin/env python3
"""inject_bodies.py — turn Apple's .swiftinterface declarations into compilable Swift source.

WHAT THIS DOES
--------------
SwiftUI/SwiftUICore ship only as closed-source binaries on Darwin. Apple *does* publish their
complete API as textual module interfaces (`.swiftinterface`) inside the iOS SDK, and
`scripts/port/build-port-sdk.sh` retargets those to `aarch64-unknown-linux-android28`
(output: `build/port-sdk/gen/<Module>.swiftmodule/*.swiftinterface`).

A `.swiftinterface` is *not* valid source: it is a declaration-only description of a module.
Outside protocols every declaration without an `@inlinable` body is illegal, opaque result
types are spelled with the compiler-internal `@_opaqueReturnTypeOf(...)` attribute, and type
names are module-qualified with `::` instead of Swift's usual `.`.

This script reads the retargeted interface and writes ordinary Swift source:

    Sources/SwiftUI/Generated/SwiftUICore.swift
    Sources/SwiftUI/Generated/SwiftUI.swift

Every declaration keeps exactly the text Apple wrote. The only changes are the *additions*
needed to make that text legal Swift outside Apple's SDK:

  * a bodyless `func` / `init` / `subscript` gets `{ _suiUnimplemented("<symbol>") }`
  * a bodyless computed property (`{ get }`, `{ get set }`, ...) gets a body on every
    bodyless accessor: `{ get { _suiUnimplemented("...") } set { _suiUnimplemented("...") } }`
  * a bodyless `deinit` gets `{}`
  * `@inlinable` bodies are Apple's own code and are kept byte-for-byte, never touched
  * protocol requirements keep no body (that is legal Swift)

`_suiUnimplemented` is the seam to the port engine: it is defined once in
`Sources/SwiftUI/Engine/PortRuntime.swift`, which compiles into the same module as the generated
files. Every synthetic body calls it; the engine replaces a declaration by listing its symbol in
`port-impl/implemented.txt` (see "ENGINE OVERRIDES" below).

Both generated files compile into the *single* module named `SwiftUI` (`Package.swift` has one
target). Apple's SwiftUI/SwiftUICore split is their binary layout; here SwiftUICore's
declarations are simply part of the same module, so their `SwiftUICore::` / `SwiftUICore.`
qualifiers and the `@_exported import SwiftUICore` are removed (R1).

The result is deterministic: declarations are emitted in Apple's order, no timestamps, no
environment-dependent text. Re-running the script on the same interface reproduces the same
bytes; `--check` verifies that.

OUTPUT MANIFEST
---------------
`build/port-sdk/injected-bodies.json` describes everything the generator did, per file and in
total: declarations reproduced, bodies injected, `@inlinable` bodies preserved, rewrite counts,
the list of stubbed symbols, and the engine seam list.

    {
      "schema": 1,
      "target": "aarch64-unknown-linux-android28",
      "compiled_module": "SwiftUI",
      "layout": "single-module: Generated/SwiftUICore.swift + Generated/SwiftUI.swift compile into module SwiftUI",
      "files": {"SwiftUICore.swift": "SwiftUICore", "SwiftUI.swift": "SwiftUI"},
      "modules": { "SwiftUICore": {...counts...}, "SwiftUI": {...counts...} },
      "stats": { ...sums... },
      "seams": {
        "body": {"count": 318, "symbols": ["SwiftUICore.Text.body", ...]},
        "_makeView(view:inputs:)": {"count": 200, "symbols": [...]},
        "_makeViewList(view:inputs:)": {"count": 40, "symbols": [...]},
        "_viewListCount(inputs:)": {"count": 20, "symbols": [...]},
        "total": 578
      },
      "overridden": {"count": 12, "symbols": [...]},
      "synthesized_projections_omitted": {"count": 10, "symbols": [...]},
      "bodies": [
        {"symbol": "SwiftUICore.LayoutDirection.hash(into:)", "module": "SwiftUICore",
         "kind": "func", "inlined": false},
        ...
        {"symbol": "SwiftUICore.View.disabled(_:)", "module": "SwiftUICore",
         "kind": "func", "inlined": true}
      ]
    }

Symbol spelling (also the key used by `port-impl/implemented.txt`)::

    <Apple module>.<Type path>.<member>(<external labels, each with ':'>)

  * the Apple module is `SwiftUICore` or `SwiftUI` (where Apple declares it), even though both
    compile into module `SwiftUI`;
  * the type path drops module qualifiers and generic arguments: `SwiftUICore.ForEach.body`,
    not `ForEach<Data, ID, Content>.body`;
  * a function / initializer / subscript name includes its external parameter labels:
    `SwiftUI.VStack._makeView(view:inputs:)`, `SwiftUICore.Text.font(_:)`,
    `SwiftUICore.ForEach.init(_:content:)`, `SwiftUICore.Text.subscript(dynamicMember:)`;
  * a property is `Type.name` with no labels: `SwiftUICore.Text.body`, `SwiftUI.Link.body`.

`inlined: false` means "the port must implement this": the body is a placeholder that traps at
runtime and reports the symbol. `inlined: true` means Apple shipped an `@inlinable` body, which
is real Apple code (it may still reach stub bodies, but its own logic is Apple's).

ENGINE OVERRIDES (`port-impl/implemented.txt`)
---------------------------------------------
The generated module is a scaffold: the engine replaces the entry points it implements. Put one
qualified symbol per line (exact manifest spelling; `#` comments and blank lines are allowed)::

    # port-impl/implemented.txt
    SwiftUICore.Text.body
    SwiftUI.VStack._makeView(view:inputs:)
    SwiftUICore.Text.font(_:)

For every listed symbol the generator *omits the declaration* from the generated output, so the
engine can declare it with a real body in an extension in the same module::

    extension Text {
        public var body: some View { ... }             // witness in an extension is legal
        public func font(_ font: Font?) -> Text { ... }
    }

Details:
  * if the omitted symbol is an opaque witness (`var body: some View`), the generator also omits
    that type's `@_opaqueReturnTypeOf` associated-type spelling, so Swift infers `Body` from the
    engine's witness instead of pinning it to `Never`;
  * a *stored instance property* cannot be omitted (extensions cannot add storage); the
    generator reports it and refuses;
  * class designated initializers must be declared in the class body in Swift, so overriding a
    class's designated `init` cannot move it into an extension either -- keep those generated;
  * every symbol must match a bodyless declaration; unknown symbols are a hard error so typos in
    the override file cannot silently do nothing;
  * if the file does not exist, nothing is overridden.

DOCUMENTED REWRITE RULES
------------------------
Bodies are *additions*: they never change a declaration. Only the rules below change declaration
text, and every one of them is listed in the banner of the generated files and explained, with
the Apple construct it handles and the reason, in `docs/PORT-BODIES.md`:

  R1  `SwiftUICore::Foo` / `SwiftUICore.Foo` -> `Foo`, and `@_exported import SwiftUICore` is
      dropped: both interfaces compile into the one port module, so those names are local
      (`::` is interface-only spelling; a module cannot import itself).
  R2  interface-only stored `static let` / `static var` -> read-only computed `static var`
      with an injected getter. A `.swiftinterface` describes static storage that lives in
      Apple's binary as `static let x: T` with no initializer; that spelling does not compile
      as source ("`static let` declaration requires an initializer expression or an explicitly
      stated getter"). The public API is unchanged: a read-only type property.
      (`let` becomes `var` because Swift has no computed `let`; both are read-only from the
      outside, so the API is identical.) Stored properties declared in extensions are treated
      the same way.
  R3  opaque result types that cannot be expressed as source:
        - `@_opaqueReturnTypeOf("$s...", 0) __<...>` typealiases (resolved against Apple's
          binary symbols only) become `Swift.Never`;
        - a bodyless member whose opaque result is a protocol that declares no
          `extension Never : P` (Apple declares those for View, Scene, Shape, ... itself)
          becomes concrete `Swift.Never`, because the port has no value to return and
          `Never` needs no conformance once it *is* the declared type.
      `Never` is the port's bottom type; Apple declares the conformances it needs.
  R4  `#if` conditionals whose condition is an Apple-compiler feature flag
      (`compiler(>=5.3) && $TildeSendable`, `$InlineAlways`, `$AsyncExecutionBehaviorAttributes`)
      are evaluated for the pinned toolchain (Swift 6.4.3: all true). Bodies are injected only
      into the branch that is compiled; the dead fallback branch is preserved verbatim, so the
      file still shows exactly what Apple declares.
  R5  `$`-prefixed declarations (`public var $selection: ...`) are omitted: the `$` prefix is
      reserved for implicitly-synthesised property-wrapper projections, so the spelling cannot
      exist in source ("cannot declare entity named '$selection'"). Swift synthesises the
      projection from the wrapper property; the port does not use Apple's wrappers, so the
      projected value is not part of its surface.
  R6  symbols listed in `port-impl/implemented.txt` are omitted so the engine can implement them
      (see "ENGINE OVERRIDES").

Project rule: no public declaration is deleted to make an error go away. R5 and R6 are the only
omissions; both are explicit and recorded in the manifest and docs. Anything else that cannot be
represented stops the generator with a precise error.

USAGE
-----
    scripts/port/inject_bodies.py              # regenerate Generated/*.swift + manifest
    scripts/port/inject_bodies.py --check      # verify files on disk are up to date (CI)
    scripts/port/generate.sh                   # regenerate + cross-compile check
    scripts/port/generate.sh --no-build        # regenerate only

See `docs/PORT-BODIES.md` for the rewrite-rule details, the manifest format, the override file
and the exact cross-compile commands.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import time
from bisect import bisect_right
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

TARGET = "aarch64-unknown-linux-android28"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GEN_DIR = os.path.join(ROOT, "build", "port-sdk", "gen")
OUT_DIR = os.path.join(ROOT, "Sources", "SwiftUI", "Generated")
MANIFEST_PATH = os.path.join(ROOT, "build", "port-sdk", "injected-bodies.json")

#: Both Apple interfaces are compiled into this one port module (`Package.swift` has a single
#: `SwiftUI` target). Apple's two-module split is their binary layout, not the port's.
COMPILED_MODULE = "SwiftUI"


@dataclass(frozen=True)
class ModuleSpec:
    """One Apple module interface and how it is materialised in the port module."""

    interface_module: str  # Apple module name / directory in build/port-sdk/gen
    file_stem: str  # output file: Sources/SwiftUI/Generated/<file_stem>.swift
    requalify: tuple[str, ...]  # Apple modules whose references become `SwiftUI.<name>`
    drop_imports: tuple[str, ...]  # prelude imports removed (those names are local)


MODULE_SPECS = (
    ModuleSpec("SwiftUICore", "SwiftUICore", requalify=("SwiftUICore",), drop_imports=()),
    ModuleSpec("SwiftUI", "SwiftUI", requalify=("SwiftUICore",), drop_imports=("SwiftUICore",)),
)
MODULES = tuple(spec.interface_module for spec in MODULE_SPECS)

#: `port-impl/implemented.txt`: symbols the engine implements, omitted from generated output.
IMPLEMENTED_PATH = os.path.join(ROOT, "port-impl", "implemented.txt")

# ---------------------------------------------------------------------------
# Swift lexical knowledge
# ---------------------------------------------------------------------------

MODIFIERS = {
    "public", "private", "internal", "fileprivate", "package", "open",
    "static", "final", "override", "required", "convenience",
    "nonisolated", "mutating", "nonmutating", "lazy", "weak", "unowned",
    "dynamic", "optional", "indirect", "distributed",
    "prefix", "postfix", "infix",
    "sending", "consuming", "borrowing",
}

TYPE_KEYWORDS = {"struct", "class", "enum", "protocol", "extension", "actor"}
DECL_KEYWORDS = TYPE_KEYWORDS | {
    "func", "init", "deinit", "var", "let", "subscript",
    "typealias", "associatedtype", "case", "import", "macro",
    "operator", "precedencegroup",
}
ACCESSOR_KEYWORDS = {"get", "set", "_modify", "_read", "willSet", "didSet", "init"}
OPERATOR_CHARS = set("=+-*/%<>&|^~?!.")
#: Attributes that mark a declaration as carrying Apple's own (real) body.
INLINABLE_ATTRS = {"inlinable"}
#: Extra modifiers that can precede a parameter's external name.
PARAM_MODIFIERS = MODIFIERS | {"inout", "__owned", "__shared", "isolated", "each"}

#: Module names that can qualify a type path in the retargeted interfaces. Used to strip
#: repeated module qualification (`SwiftUICore::SwiftUICore::Text` -> `Text`).
MODULE_NAMES = {
    "SwiftUICore", "SwiftUI", "Swift", "_Concurrency", "_StringProcessing",
    "Accessibility", "Combine", "CoreData", "CoreFoundation", "CoreGraphics", "CoreMedia",
    "CoreText", "CoreTransferable", "Darwin", "DataDetection", "DeveloperToolsSupport",
    "Dispatch", "Foundation", "FoundationNetworking", "FoundationShims", "ObjectiveC",
    "Observation", "OSLog", "QuartzCore", "Spatial", "Symbols", "UIKit",
    "UniformTypeIdentifiers", "os", "simd",
}

#: Modifiers that must be preserved when a protocol requirement is turned into a witness.
WITNESS_MODIFIERS = {
    "static", "nonisolated", "mutating", "nonmutating",
    "consuming", "borrowing", "prefix", "postfix", "infix",
}

#: `Never` conformances the standard library declares (`Never` conforms to these in Swift 6.4).
STDLIB_NEVER_CONFORMANCES = {
    "Equatable", "Hashable", "Comparable", "Sendable",
    "Encodable", "Decodable", "Codable", "Error",
    "CustomStringConvertible", "CustomDebugStringConvertible", "Escapable",
}


class GenerationError(Exception):
    """Raised when the generator cannot produce a compilable, faithful module."""


class ParseError(Exception):
    """Raised when the interface contains a construct this script does not understand."""

    def __init__(self, text: str, offset: int, message: str) -> None:
        line = text.count("\n", 0, offset) + 1
        column = offset - (text.rfind("\n", 0, offset) + 1) + 1
        super().__init__(f"line {line}:{column}: {message}")
        self.message = message


# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------


@dataclass
class Token:
    text: str
    start: int
    end: int
    kind: str  # "id" | "punct" | "string" | "number"


def _scan_string(text: str, i: int) -> int:
    """Return the offset just past the string literal that starts at ``i``.

    Handles raw strings (``#"..."#``), multi-line strings and interpolation (``\\( ... )``)
    including nested strings and parentheses inside the interpolation.
    """
    n = len(text)
    hashes = 0
    while i + hashes < n and text[i + hashes] == "#":
        hashes += 1
    j = i + hashes
    if j >= n or text[j] != '"':
        raise ValueError("not a string literal")
    quote = '"""' if text.startswith('"""', j) else '"'
    closing = quote + "#" * hashes
    escape = "\\" + "#" * hashes
    j += len(quote)
    while j < n:
        if text.startswith(closing, j):
            return j + len(closing)
        if text.startswith(escape, j):
            k = j + len(escape)
            if k < n and text[k] == "(":
                depth = 0
                while k < n:
                    ch = text[k]
                    if ch == '"':
                        k = _scan_string(text, k)
                        continue
                    if ch == "/" and k + 1 < n and text[k + 1] == "/":
                        nl = text.find("\n", k)
                        k = n if nl < 0 else nl
                        continue
                    if ch in "([{":
                        depth += 1
                    elif ch in ")]}":
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    k += 1
                j = k
                continue
            j = k + 1
            continue
        j += 1
    raise ValueError("unterminated string literal")


def tokenize(text: str) -> list[Token]:
    """Tokenize Swift source just enough to track declarations, braces and strings.

    Comments are dropped; everything else is emitted as ``id``, ``number``, ``string`` or
    single-character punctuation. The script never rebuilds source from tokens -- it only needs
    offsets -- so tokens only have to be exact for identifiers and punctuation.
    """
    tokens: list[Token] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch in " \t\r\n":
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            j = i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            i = j
            continue
        if ch == "#" and i + 1 < n and text[i + 1] == '"':
            j = _scan_string(text, i)
            tokens.append(Token(text[i:j], i, j, "string"))
            i = j
            continue
        if ch == '"':
            j = _scan_string(text, i)
            tokens.append(Token(text[i:j], i, j, "string"))
            i = j
            continue
        if ch == "`":
            j = text.find("`", i + 1)
            if j < 0:
                raise ValueError("unterminated backticked identifier")
            tokens.append(Token(text[i + 1:j], i, j + 1, "id"))
            i = j + 1
            continue
        if ch.isalpha() or ch in "_$":
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] in "_$"):
                j += 1
            tokens.append(Token(text[i:j], i, j, "id"))
            i = j
            continue
        if ch.isdigit():
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] in "._"):
                j += 1
            tokens.append(Token(text[i:j], i, j, "number"))
            i = j
            continue
        tokens.append(Token(ch, i, i + 1, "punct"))
        i += 1
    return tokens


# ---------------------------------------------------------------------------
# Conditional compilation (`#if` ... `#else` ... `#endif`)
# ---------------------------------------------------------------------------

#: Feature conditions the retargeted interfaces use. Swift 6.4.3 defines all three; they only
#: choose between two spellings of the *same* API (with/without `~Sendable`, `@inline(always)`
#: vs `@inline(__always)`), so on the pinned toolchain the `#if` branch is the live one.
ACTIVE_FEATURE_CONDITIONS = {
    "compiler(>=5.3)",
    "$TildeSendable",
    "$InlineAlways",
    "$AsyncExecutionBehaviorAttributes",
}

_DIRECTIVE_RE = re.compile(r"^[ \t]*#(if|elseif|else|endif)\b(.*)$")


def _eval_condition(expr: str, text: str, offset: int) -> bool:
    """Evaluate an interface `#if` condition. Only the known feature flags are supported."""
    expr = expr.strip()
    if not expr:
        raise ParseError(text, offset, "empty #if condition")
    parts = re.split(r"\s*(&&|\|\|)\s*", expr)
    result: bool | None = None
    operator: str | None = None
    for part in parts:
        if part in ("&&", "||"):
            operator = part
            continue
        atom = part.strip()
        if atom not in ACTIVE_FEATURE_CONDITIONS:
            raise ParseError(
                text, offset,
                f"unsupported #if condition {atom!r}: add it to ACTIVE_FEATURE_CONDITIONS "
                "after checking which branch the pinned toolchain compiles",
            )
        if result is None:
            result = True
        elif operator == "&&":
            result = result and True
        elif operator == "||":
            result = result or True
        else:
            raise ParseError(text, offset, f"malformed #if condition {expr!r}")
    return bool(result)


def preprocess_conditionals(body: str) -> str:
    """Blank out `#if` directive lines and dead branches, keeping byte offsets intact.

    The returned text has the same length as ``body`` (every blanked character becomes a
    space, newlines are kept), so offsets produced by the parser are directly usable as edit
    offsets into the original text. Only the branch the pinned toolchain compiles keeps its
    tokens; dead branches are preserved verbatim in the output but are not parsed.
    """
    lines: list[tuple[int, int]] = []
    start = 0
    for line in body.splitlines(keepends=True):
        lines.append((start, start + len(line)))
        start += len(line)
    if start < len(body):
        lines.append((start, len(body)))

    out = list(body)
    stack: list[dict] = []
    active = True

    def blank(line_start: int, line_end: int) -> None:
        for k in range(line_start, line_end):
            if out[k] != "\n":
                out[k] = " "

    for line_start, line_end in lines:
        raw = body[line_start:line_end].rstrip("\n")
        match = _DIRECTIVE_RE.match(raw)
        if match:
            kind, rest = match.group(1), match.group(2)
            if kind == "if":
                cond = _eval_condition(rest, body, line_start)
                stack.append({"outer": active, "any_taken": cond, "taken": cond})
                active = active and cond
            elif kind == "elseif":
                if not stack:
                    raise ParseError(body, line_start, "#elseif without #if")
                frame = stack[-1]
                cond = _eval_condition(rest, body, line_start) if frame["outer"] else False
                active = frame["outer"] and not frame["any_taken"] and cond
                frame["taken"] = active
                frame["any_taken"] = frame["any_taken"] or cond
            elif kind == "else":
                if not stack:
                    raise ParseError(body, line_start, "#else without #if")
                frame = stack[-1]
                active = frame["outer"] and not frame["any_taken"]
                frame["taken"] = active
                frame["any_taken"] = True
            elif kind == "endif":
                if not stack:
                    raise ParseError(body, line_start, "#endif without #if")
                active = stack.pop()["outer"]
            blank(line_start, line_end)
            continue
        if not active:
            blank(line_start, line_end)
    if stack:
        raise ParseError(body, len(body), "unterminated #if block")
    return "".join(out)


# ---------------------------------------------------------------------------
# Declaration model
# ---------------------------------------------------------------------------


@dataclass
class Accessor:
    keyword: str
    keyword_end: int  # offset just past the keyword: where a body starts
    has_body: bool
    inlinable: bool


@dataclass
class Member:
    kind: str  # func | init | deinit | var | let | subscript | typealias | ...
    name: str  # display name, e.g. "padding(_:)" / "body" / "init(_:)"
    start: int  # offset of the first attribute/modifier token
    end: int  # offset just past the last token of the declaration
    static: bool = False
    inlinable: bool = False
    has_body: bool = False
    accessors: list[Accessor] = field(default_factory=list)
    #: span of the declared result type / property type, for opaque-result handling (R3)
    result_type_span: tuple[int, int] | None = None
    #: span of an `@_opaqueReturnTypeOf(...)` right-hand side (R3)
    opaque_typealias_span: tuple[int, int] | None = None
    #: span of the declaration keyword (`func`, `var`, `init`, ...)
    keyword_span: tuple[int, int] | None = None
    #: attributes/modifiers that preceded the keyword, as parsed from the source
    prefix: list[tuple[str, str]] = field(default_factory=list)
    #: offset of the `{` that opens the body / accessor block, if the declaration has one
    block_start: int | None = None


@dataclass
class Container:
    kind: str  # module | struct | class | enum | protocol | extension | actor
    path: str  # type path without module qualifier, e.g. "Text.LineStyle"
    start: int
    end: int = 0
    members: list[Member] = field(default_factory=list)
    children: list["Container"] = field(default_factory=list)
    conformances: list[str] = field(default_factory=list)
    #: True for `@propertyWrapper` types (their attribute spellings are not source-legal here)
    is_property_wrapper: bool = False
    #: True when the declaration carries a `where` clause (used to tell unconstrained defaults)
    has_where: bool = False
    #: True for `@resultBuilder` / `@_functionBuilder` types
    is_result_builder: bool = False


# ---------------------------------------------------------------------------
# Type-path helpers
# ---------------------------------------------------------------------------

_WHERE_RE = re.compile(r"\s+where\s")


def _strip_generics(text: str) -> str:
    while "<" in text:
        start = text.index("<")
        depth = 0
        for index in range(start, len(text)):
            if text[index] == "<":
                depth += 1
            elif text[index] == ">":
                depth -= 1
                if depth == 0:
                    text = text[:start] + text[index + 1:]
                    break
        else:
            break
    return text


def split_top_level_comma(text: str) -> list[str]:
    """Split a parenthesised list body on top-level commas (type levels only)."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    index = 0
    while index < len(text):
        ch = text[index]
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
        index += 1
    parts.append("".join(current))
    return [part.strip() for part in parts if part.strip()]


def normalize_type_path(raw: str) -> str:
    """Normalise an interface-spelled type path to the port's symbol path.

    ``SwiftUICore::Text.SwiftUICore::LineStyle`` -> ``Text.LineStyle``;
    ``SwiftUICore.View where Self.Body == Never`` -> ``View``;
    ``CoreGraphics::CGPoint`` -> ``CGPoint``.
    """
    text = raw.strip()
    text = _WHERE_RE.split(text)[0]
    text = text.replace("::", ".")
    # Drop an inheritance clause at the top level.
    depth = 0
    cut = len(text)
    for index, ch in enumerate(text):
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
        elif ch == ":" and depth == 0:
            cut = index
            break
    text = text[:cut].strip()
    text = _strip_generics(text)
    parts = [part for part in text.strip().split(".") if part]
    # Drop module-name components: the interface printer qualifies nested lookups as well
    # (`SwiftUICore::SystemFormatStyle.SwiftUICore::DateReference`), and a repeated module name
    # must not leak into the port's type paths.
    parts = [part for part in parts if part not in MODULE_NAMES]
    return ".".join(parts)


def base_protocol_name(type_text: str) -> str:
    """``some SwiftUICore::View`` / ``some Swift.Sequence<...>`` -> ``View`` / ``Sequence``."""
    match = re.search(r"\bsome\b(.*)$", type_text, re.S)
    rest = match.group(1) if match else type_text
    rest = rest.replace("::", ".").strip()
    rest = _strip_generics(rest)
    # Compositions (`some A & B`) keep the first protocol; `Never` has no such conformance.
    rest = rest.split("&")[0].strip()
    parts = [part for part in rest.split(".") if part]
    if not parts:
        return ""
    return parts[-1]


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


class Parser:
    def __init__(self, text: str, parse_text: str) -> None:
        self.text = text
        self.parse_text = parse_text
        self.tokens = tokenize(parse_text)
        self.i = 0
        self.line_starts: list[int] = [0]
        line_start = 0
        for match in re.finditer(r"\n", parse_text):
            self.line_starts.append(match.end())

    # -- token helpers ----------------------------------------------------
    def tok(self, offset: int = 0) -> Token | None:
        index = self.i + offset
        return self.tokens[index] if index < len(self.tokens) else None

    def peek_text(self, offset: int = 0) -> str | None:
        token = self.tok(offset)
        return token.text if token else None

    def at_end(self) -> bool:
        return self.i >= len(self.tokens)

    def line_index(self, offset: int) -> int:
        return bisect_right(self.line_starts, offset) - 1

    def is_first_on_line(self, token: Token) -> bool:
        line = self.line_index(token.start)
        return self.parse_text[self.line_starts[line]:token.start].strip() == ""

    def starts_declaration_line(self, token: Token) -> bool:
        """True if ``token`` is the first token of a line that starts a declaration."""
        if not self.is_first_on_line(token):
            return False
        if token.text in ("@", "}", "}"):
            return True
        return token.kind == "id" and token.text in MODIFIERS | DECL_KEYWORDS

    def skip_balanced(self, index: int) -> int:
        """``index`` points at `(`, `[` or `{`; return the index just past its match."""
        openers = {"(": ")", "[": "]", "{": "}"}
        opener = self.tokens[index].text
        if opener not in openers:
            raise ParseError(
                self.text, self.tokens[index].start,
                f"expected a bracket, got {opener!r}",
            )
        depth = 0
        while index < len(self.tokens):
            token = self.tokens[index]
            if token.text in openers:
                depth += 1
            elif token.text in (")", "]", "}"):
                depth -= 1
                if depth == 0:
                    return index + 1
            index += 1
        raise ParseError(self.text, self.tokens[self.i].start, "unbalanced brackets")

    def skip_angle(self, index: int) -> int:
        """``index`` points at `<` opening a generic argument/parameter clause."""
        depth = 0
        while index + 1 < len(self.tokens):
            token = self.tokens[index]
            if token.text == "-" and self.tokens[index + 1].text == ">":
                index += 2  # `->` arrows are not closing angle brackets
                continue
            if token.text == "<":
                depth += 1
            elif token.text == ">":
                depth -= 1
                if depth == 0:
                    return index + 1
            index += 1
        raise ParseError(self.text, self.tokens[self.i].start, "unbalanced generic brackets")

    def skip_attribute(self) -> None:
        """Consume one attribute: ``@Name``, ``@Module.Name`` / ``@Module::Name``, args."""
        assert self.tokens[self.i].text == "@"
        self.i += 1
        if self.at_end():
            raise ParseError(self.text, self.tokens[-1].start, "attribute without a name")
        self.i += 1
        while not self.at_end():
            if self.tokens[self.i].text == ".":
                self.i += 2
                continue
            if (
                self.tokens[self.i].text == ":"
                and self.peek_text(1) == ":"
            ):
                self.i += 3  # `@Module::Attribute` (interface spelling)
                continue
            break
        if not self.at_end() and self.tokens[self.i].text == "<":
            self.i = self.skip_angle(self.i)  # `@SwiftUICore::KeyframesBuilder<Self.Value>`
        if not self.at_end() and self.tokens[self.i].text == "(":
            self.i = self.skip_balanced(self.i)

    def read_prefix(self) -> list[tuple[str, str]]:
        """Consume attributes and modifiers; return them as (kind, name) pairs."""
        prefix: list[tuple[str, str]] = []
        while not self.at_end():
            token = self.tokens[self.i]
            if token.text == "@":
                name_index = self.i + 1
                self.skip_attribute()
                prefix.append(("attr", self.tokens[name_index].text))
                continue
            if token.kind == "id" and token.text in MODIFIERS:
                self.i += 1
                if not self.at_end() and self.tokens[self.i].text == "(":
                    self.i = self.skip_balanced(self.i)  # nonisolated(unsafe), private(set)
                prefix.append(("mod", token.text))
                continue
            if token.text == "class" and self.peek_text(1) in ("func", "var", "subscript"):
                self.i += 1
                prefix.append(("mod", "class"))
                continue
            break
        return prefix

    def current_line(self) -> int:
        return self.line_index(self.tokens[self.i].start)

    def consume_current_line(self) -> None:
        """Consume every token on the line of the current token."""
        line = self.current_line()
        while not self.at_end() and self.line_index(self.tokens[self.i].start) == line:
            self.i += 1

    # -- scanning helpers -------------------------------------------------
    def scan_type(self, index: int) -> tuple[int, int]:
        """Consume a type expression; return ``(next_index, end_offset)``.

        A type ends at a declaration boundary: `{`, `}`, `where`, a first-on-line token that
        starts a declaration, or end of input. Parens/brackets are balanced.
        """
        if index >= len(self.tokens):
            return index, len(self.text)
        last_end = self.tokens[index - 1].end if index else 0
        depth = 0
        while index < len(self.tokens):
            token = self.tokens[index]
            if depth == 0:
                if token.text in ("{", "}"):
                    return index, last_end
                if token.text == "where":
                    return index, last_end
                if self.starts_declaration_line(token):
                    return index, last_end
            if token.text in ("(", "["):
                depth += 1
            elif token.text in (")", "]"):
                depth -= 1
                if depth < 0:
                    return index, last_end
            last_end = token.end
            index += 1
        return index, last_end

    def skip_braces(self) -> None:
        """``self.i`` points at `{`; consume through the matching `}`."""
        self.i = self.skip_balanced(self.i)

    def consume_expression(self) -> None:
        """Consume an initializer expression up to the declaration boundary."""
        self.i, _ = self.scan_type(self.i)

    def consume_to_declaration_end(self) -> int:
        """Consume tokens until the next declaration starts; return the end offset."""
        last_end = self.tokens[self.i - 1].end
        while not self.at_end():
            token = self.tokens[self.i]
            if token.text == "}":
                break
            if self.starts_declaration_line(token):
                break
            if token.text in ("(", "[", "{"):
                start_index = self.i
                self.i = self.skip_balanced(self.i)
                last_end = self.tokens[self.i - 1].end
                continue
            last_end = token.end
            self.i += 1
        return last_end

    # -- parse entry point ------------------------------------------------
    def parse(self) -> Container:
        root = Container(kind="module", path="", start=0)
        self.parse_container(root)
        if self.i != len(self.tokens):
            token = self.tokens[self.i]
            raise ParseError(self.text, token.start, f"unexpected token {token.text!r}")
        return root

    def parse_container(self, container: Container) -> None:
        while not self.at_end():
            token = self.tokens[self.i]
            if token.text == "}":
                if container.kind == "module":
                    raise ParseError(self.text, token.start, "unexpected '}'")
                self.i += 1
                return
            self.parse_declaration(container)
        if container.kind != "module":
            raise ParseError(
                self.text, len(self.text),
                f"unterminated {container.kind} {container.path or '<module>'}",
            )

    # -- declarations ------------------------------------------------------
    def parse_declaration(self, container: Container) -> None:
        start = self.tokens[self.i].start
        prefix = self.read_prefix()
        if self.at_end():
            raise ParseError(self.text, start, "declaration without a keyword")
        token = self.tokens[self.i]
        keyword = token.text

        if keyword == "import":
            self.consume_current_line()
            container.members.append(Member("import", "import", start, self.tokens[self.i - 1].end))
            return
        if keyword in TYPE_KEYWORDS:
            self.parse_type(container, keyword, prefix, start)
            return
        if keyword in ("func", "init", "subscript"):
            container.members.append(self.parse_callable(container, keyword, prefix, start))
            return
        if keyword in ("var", "let"):
            container.members.append(self.parse_property(keyword, prefix, start))
            return
        if keyword == "deinit":
            container.members.append(self.parse_deinit(prefix, start))
            return
        if keyword == "typealias":
            container.members.append(self.parse_typealias(prefix, start))
            return
        if keyword in ("associatedtype", "case", "macro", "operator"):
            end = self.consume_after_keyword()
            container.members.append(Member(keyword, keyword, start, end))
            return
        if keyword == "precedencegroup":
            self.i += 1
            while not self.at_end() and self.tokens[self.i].text != "{":
                self.i += 1
            if self.at_end():
                raise ParseError(self.text, start, "precedencegroup without a body")
            self.skip_braces()
            container.members.append(
                Member("precedencegroup", "precedencegroup", start, self.tokens[self.i - 1].end)
            )
            return
        raise ParseError(
            self.text, token.start,
            f"unsupported declaration keyword {keyword!r} in "
            f"{container.kind} {container.path or '<module>'}",
        )

    def consume_after_keyword(self) -> int:
        """Consume the rest of a keyword-led declaration (``case``, ``associatedtype``, ...)."""
        self.i += 1
        return self.consume_to_declaration_end()

    def parse_type(
        self, container: Container, keyword: str, prefix: list[tuple[str, str]], start: int
    ) -> None:
        self.i += 1  # keyword
        if keyword == "extension":
            if self.at_end():
                raise ParseError(self.text, start, "extension without a body")
            name_start = self.tokens[self.i].start
            while not self.at_end() and self.tokens[self.i].text != "{":
                token = self.tokens[self.i]
                if token.text in ("(", "["):
                    self.i = self.skip_balanced(self.i)
                    continue
                if token.text == "<":
                    self.i = self.skip_angle(self.i)
                    continue
                if token.text == "}":
                    raise ParseError(self.text, token.start, "extension without a body")
                self.i += 1
            if self.at_end():
                raise ParseError(self.text, start, "extension without a body")
            header_end = self.tokens[self.i - 1].end
            header = self.text[name_start:header_end]
            name = normalize_type_path(header)
            conformances = self.parse_conformances(header)
            path = name
            child = Container(
                kind="extension",
                path=path,
                start=start,
                conformances=conformances,
                has_where=" where " in header,
                is_property_wrapper=any(
                    kind == "attr" and name_ == "propertyWrapper" for kind, name_ in prefix
                ),
                is_result_builder=any(
                    kind == "attr" and name_ in ("resultBuilder", "_functionBuilder")
                    for kind, name_ in prefix
                ),
            )
        else:
            name_token = self.tokens[self.i]
            if name_token.kind != "id":
                raise ParseError(self.text, name_token.start, f"expected a type name after {keyword}")
            name = name_token.text
            self.i += 1
            header_start = name_token.end
            while not self.at_end() and self.tokens[self.i].text != "{":
                token = self.tokens[self.i]
                if token.text in ("(", "["):
                    self.i = self.skip_balanced(self.i)
                    continue
                if token.text == "<":
                    self.i = self.skip_angle(self.i)
                    continue
                if token.text == "}":
                    raise ParseError(self.text, token.start, f"{keyword} {name} without a body")
                self.i += 1
            if self.at_end():
                raise ParseError(self.text, start, f"{keyword} {name} without a body")
            path = f"{container.path}.{name}" if container.path else name
            header_end = self.tokens[self.i - 1].end
            child = Container(
                kind=keyword,
                path=path,
                start=start,
                conformances=self.parse_conformances(self.text[header_start:header_end]),
                is_property_wrapper=any(
                    kind == "attr" and name_ == "propertyWrapper" for kind, name_ in prefix
                ),
                is_result_builder=any(
                    kind == "attr" and name_ in ("resultBuilder", "_functionBuilder")
                    for kind, name_ in prefix
                ),
            )

        container.children.append(child)
        self.i += 1  # past '{'
        self.parse_container(child)
        child.end = self.tokens[self.i - 1].end

    def parse_conformances(self, header: str) -> list[str]:
        # `::` is the interface spelling of module qualification; it is not an inheritance colon,
        # so normalise it before looking for the conformance list (otherwise
        # `extension SwiftUI::Text : SwiftUI::View` yields no conformances at all).
        text = _WHERE_RE.split(header)[0].replace("::", ".")
        depth = 0
        for index, ch in enumerate(text):
            if ch in "<([":
                depth += 1
            elif ch in ">)]":
                depth -= 1
            elif ch == ":" and depth == 0:
                conformances = []
                for part in split_top_level_comma(text[index + 1:]):
                    name = normalize_type_path(part)
                    if name:
                        conformances.append(name.split(".")[-1])
                return conformances
        return []

    def parse_callable(
        self, container: Container, kind: str, prefix: list[tuple[str, str]], start: int
    ) -> Member:
        keyword_token = self.tokens[self.i]
        self.i += 1  # keyword
        labels = ""
        if kind == "func":
            token = self.tok()
            if token is None:
                raise ParseError(self.text, start, "func without a name")
            if token.kind == "id":
                name = token.text
                self.i += 1
            else:
                name_start_index = self.i
                while not self.at_end():
                    token = self.tokens[self.i]
                    if token.text == "-" and self.peek_text(1) == ">":
                        break
                    if token.text not in OPERATOR_CHARS:
                        break
                    self.i += 1
                name = "".join(t.text for t in self.tokens[name_start_index:self.i])
                if not name:
                    raise ParseError(self.text, token.start, f"unsupported function name {token.text!r}")
            if self.peek_text() == "<":
                self.i = self.skip_angle(self.i)
        else:
            if kind == "init" and self.peek_text() in ("?", "!"):
                self.i += 1
            name = kind
            if self.peek_text() == "<":
                self.i = self.skip_angle(self.i)

        if self.peek_text() != "(":
            raise ParseError(
                self.text, self.tokens[self.i].start if not self.at_end() else start,
                f"expected a parameter list in {kind} {name}",
            )
        params_start = self.i
        params_end_index = self.skip_balanced(self.i)
        labels = self.parameter_labels(params_start, params_end_index)
        self.i = params_end_index

        # Effects (`async`, `throws`, `throws(E)`, `rethrows`).
        while self.peek_text() in ("async", "throws", "rethrows", "reasync"):
            self.i += 1
            if self.peek_text() == "(":
                self.i = self.skip_balanced(self.i)

        # Result type.
        result_span: tuple[int, int] | None = None
        if self.peek_text() == "-" and self.peek_text(1) == ">":
            self.i += 2
            if self.at_end():
                raise ParseError(self.text, start, f"{kind} {name} is missing a result type")
            result_start = self.tokens[self.i].start
            self.i, result_end = self.scan_type(self.i)
            result_span = (result_start, result_end)

        # Where clause.
        if self.peek_text() == "where":
            self.i += 1
            self.i, _ = self.scan_type(self.i)

        accessors: list[Accessor] = []
        has_body = False
        block_start: int | None = None
        if not self.at_end() and self.tokens[self.i].text == "{":
            block_start = self.tokens[self.i].start
            if kind == "subscript":
                accessors = self.parse_accessors()
            else:
                has_body = True
                self.skip_braces()
        end = self.tokens[self.i - 1].end
        return Member(
            kind=kind,
            name=f"{name}({labels})",
            start=start,
            end=end,
            static=any(k == "mod" and v in ("static", "class") for k, v in prefix),
            inlinable=any(k == "attr" and v in INLINABLE_ATTRS for k, v in prefix),
            has_body=has_body,
            accessors=accessors,
            result_type_span=result_span,
            keyword_span=(keyword_token.start, keyword_token.end),
            prefix=prefix,
            block_start=block_start,
        )

    def parameter_labels(self, params_start: int, params_end_index: int) -> str:
        """Build Swift's ``label1:label2:`` signature spelling from a parameter list."""
        inner = self.tokens[params_start + 1:params_end_index - 1]
        groups: list[list[Token]] = []
        current: list[Token] = []
        depth = 0
        index = 0
        while index < len(inner):
            token = inner[index]
            if token.text == "-" and index + 1 < len(inner) and inner[index + 1].text == ">":
                current.extend([token, inner[index + 1]])
                index += 2
                continue
            if token.text in ("(", "[", "{", "<"):
                depth += 1
            elif token.text in (")", "]", "}", ">"):
                depth -= 1
            if token.text == "," and depth == 0:
                groups.append(current)
                current = []
            else:
                current.append(token)
            index += 1
        groups.append(current)

        labels: list[str] = []
        for group in groups:
            if not group:
                continue
            index = 0
            # Attributes on the parameter.
            while index < len(group) and group[index].text == "@":
                index += 1
                if index < len(group):
                    index += 1
                while index + 1 < len(group) and group[index].text == ".":
                    index += 2
                if index < len(group) and group[index].text == "(":
                    depth = 0
                    while index < len(group):
                        if group[index].text == "(":
                            depth += 1
                        elif group[index].text == ")":
                            depth -= 1
                            if depth == 0:
                                index += 1
                                break
                        index += 1
            while index < len(group) and group[index].text in PARAM_MODIFIERS:
                index += 1
            if index >= len(group):
                labels.append("?")
                continue
            token = group[index]
            if token.text == "_":
                labels.append("_")
            elif token.kind == "id":
                labels.append(token.text)
            else:
                labels.append("?")
        return "".join(f"{label}:" for label in labels)

    def parse_property(self, keyword: str, prefix: list[tuple[str, str]], start: int) -> Member:
        keyword_token = self.tokens[self.i]
        self.i += 1
        name_token = self.tok()
        if name_token is None or name_token.kind != "id":
            raise ParseError(self.text, keyword_token.start, f"{keyword} without a name")
        name = name_token.text
        self.i += 1

        result_span: tuple[int, int] | None = None
        if self.peek_text() == ":":
            self.i += 1
            if self.at_end():
                raise ParseError(self.text, start, f"{keyword} {name} is missing a type")
            result_start = self.tokens[self.i].start
            self.i, result_end = self.scan_type(self.i)
            result_span = (result_start, result_end)

        if self.peek_text() == "=":
            self.i += 1
            self.consume_expression()

        accessors: list[Accessor] = []
        has_body = False
        block_start: int | None = None
        if not self.at_end() and self.tokens[self.i].text == "{":
            block_start = self.tokens[self.i].start
            accessors = self.parse_accessors()
            has_body = bool(accessors)
        end = self.tokens[self.i - 1].end
        member = Member(
            kind=keyword,
            name=name,
            start=start,
            end=end,
            static=any(k == "mod" and v in ("static", "class") for k, v in prefix),
            inlinable=any(k == "attr" and v in INLINABLE_ATTRS for k, v in prefix),
            has_body=has_body,
            accessors=accessors,
            result_type_span=result_span,
            keyword_span=(keyword_token.start, keyword_token.end),
            prefix=prefix,
            block_start=block_start,
        )
        return member

    def parse_accessors(self) -> list[Accessor]:
        """Parse a `{ get set }` accessor block; ``self.i`` points at ``{``."""
        self.i += 1  # past '{'
        accessors: list[Accessor] = []
        while not self.at_end() and self.tokens[self.i].text != "}":
            inlinable = False
            while not self.at_end() and self.tokens[self.i].text == "@":
                name_index = self.i + 1
                self.skip_attribute()
                if self.tokens[name_index].text in INLINABLE_ATTRS:
                    inlinable = True
            while (
                not self.at_end()
                and self.tokens[self.i].kind == "id"
                and self.tokens[self.i].text in MODIFIERS
            ):
                self.i += 1  # `mutating get`, `nonmutating set`, ...
            if self.at_end():
                raise ParseError(self.text, len(self.text), "unterminated accessor block")
            token = self.tokens[self.i]
            if token.text not in ACCESSOR_KEYWORDS:
                raise ParseError(
                    self.text, token.start,
                    f"unsupported accessor {token.text!r} (expected one of {sorted(ACCESSOR_KEYWORDS)})",
                )
            self.i += 1
            if token.text == "init" and self.peek_text() == "(":
                # Init accessor (SE-0293): `@storageRestrictions(initializes: _x) init(initialValue)`.
                self.i = self.skip_balanced(self.i)
            keyword_end = self.tokens[self.i - 1].end
            has_body = False
            if not self.at_end() and self.tokens[self.i].text == "{":
                has_body = True
                self.skip_braces()
            accessors.append(Accessor(token.text, keyword_end, has_body, inlinable))
        if self.at_end():
            raise ParseError(self.text, len(self.text), "unterminated accessor block")
        self.i += 1  # past '}'
        return accessors

    def parse_deinit(self, prefix: list[tuple[str, str]], start: int) -> Member:
        token = self.tokens[self.i]
        self.i += 1
        has_body = False
        if not self.at_end() and self.tokens[self.i].text == "{":
            has_body = True
            self.skip_braces()
        return Member(
            kind="deinit",
            name="deinit",
            start=start,
            end=token.end,
            has_body=has_body,
            inlinable=any(k == "attr" and v in INLINABLE_ATTRS for k, v in prefix),
            keyword_span=(token.start, token.end),
            prefix=prefix,
        )

    def parse_typealias(self, prefix: list[tuple[str, str]], start: int) -> Member:
        keyword_token = self.tokens[self.i]
        keyword_start, keyword_end = keyword_token.start, keyword_token.end
        self.i += 1  # 'typealias'
        name_token = self.tok()
        if name_token is None or name_token.kind != "id":
            raise ParseError(self.text, start, "typealias without a name")
        name = name_token.text
        self.i += 1
        if self.peek_text() == "<":
            self.i = self.skip_angle(self.i)
        # `typealias X = <type>` may carry a `where` clause only on generic aliases; consume all.
        scan_start = self.i
        end = self.consume_to_declaration_end()
        opaque_span: tuple[int, int] | None = None
        for index in range(scan_start, self.i):
            token = self.tokens[index]
            if token.text == "@" and index + 1 < len(self.tokens) and \
                    self.tokens[index + 1].text == "_opaqueReturnTypeOf":
                opaque_span = (token.start, end)
                break
        return Member(
            kind="typealias",
            name=name,
            start=start,
            end=end,
            inlinable=any(k == "attr" and v in INLINABLE_ATTRS for k, v in prefix),
            opaque_typealias_span=opaque_span,
            keyword_span=(keyword_start, keyword_end),
            prefix=prefix,
        )


# ---------------------------------------------------------------------------
# Edit application
# ---------------------------------------------------------------------------


@dataclass
class Edit:
    start: int
    end: int
    replacement: str


def apply_edits(text: str, edits: list[Edit]) -> str:
    ordered = sorted(edits, key=lambda edit: (edit.start, edit.end))
    result: list[str] = []
    position = 0
    for edit in ordered:
        if edit.start < position:
            raise AssertionError(f"overlapping edits at byte {edit.start} (previous end {position})")
        result.append(text[position:edit.start])
        result.append(edit.replacement)
        position = edit.end
    result.append(text[position:])
    return "".join(result)


def skip_tokens(tokens: list[Token], index: int) -> int:
    """``index`` points at `(`, `[` or `<`; return the index just past its match."""
    openers = {"(": ")", "[": "]", "<": ">"}
    pairs = {"(": ")", "[": "]", "<": ">"}
    opener = tokens[index].text
    depth = 0
    while index < len(tokens):
        token = tokens[index]
        if token.text == "-" and index + 1 < len(tokens) and tokens[index + 1].text == ">":
            index += 2  # `->` is not a closing angle bracket
            continue
        if token.text == opener:
            depth += 1
        elif token.text == pairs[opener]:
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return index


def strip_attribute_prefixes(text: str, names: set[str]) -> tuple[str, int]:
    """Remove attributes whose name is in ``names`` (property wrappers, `@_projectedValueProperty`).

    Apple's interfaces spell wrapper-backed members as ``@Module.Wrapper public var x: T``.
    In source that is a *property wrapper* declaration: the compiler synthesises `$x` storage
    by querying the wrapper type. The port does not use Apple's wrappers (their projections are
    already omitted, R5), and the synthesis recurses through the generated wrapper types, so the
    attribute spelling is removed and the declaration keeps the wrapped-value type Apple printed.
    """
    tokens = tokenize(text)
    removals: list[Edit] = []
    index = 0
    while index < len(tokens):
        if tokens[index].text != "@":
            index += 1
            continue
        start = index
        index += 1
        if index >= len(tokens):
            break
        name = tokens[index].text
        index += 1
        while index < len(tokens):
            if tokens[index].text == "." and index + 1 < len(tokens) and tokens[index + 1].kind == "id":
                name = tokens[index + 1].text
                index += 2
                continue
            if (
                tokens[index].text == ":"
                and index + 2 < len(tokens)
                and tokens[index + 1].text == ":"
                and tokens[index + 2].kind == "id"
            ):
                name = tokens[index + 2].text
                index += 3
                continue
            break
        if index < len(tokens) and tokens[index].text == "<":
            index = skip_tokens(tokens, index)
        if index < len(tokens) and tokens[index].text == "(":
            index = skip_tokens(tokens, index)
        if name in names:
            removals.append(Edit(tokens[start].start, tokens[index - 1].end, ""))
    if not removals:
        return text, 0
    return apply_edits(text, removals), len(removals)


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------


@dataclass
class BodyEntry:
    symbol: str
    module: str
    kind: str
    inlined: bool


@dataclass


@dataclass
class ModuleStats:
    declarations: int = 0
    types: int = 0
    bodies_injected: int = 0
    inlinable_bodies_preserved: int = 0
    bodies_preserved: int = 0
    opaque_rewrites: int = 0
    static_storage_rewrites: int = 0
    self_qualifiers_removed: int = 0
    synthesized_projections_omitted: int = 0
    overridden: int = 0
    synthesized_witnesses: int = 0
    wrapper_attributes_removed: int = 0
    convenience_init_rewrites: int = 0
    duplicate_witnesses_omitted: int = 0
    synthesized_inits: int = 0
    incompatible_conformances_omitted: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "declarations": self.declarations,
            "types": self.types,
            "bodies_injected": self.bodies_injected,
            "bodies_preserved": self.bodies_preserved,
            "inlinable_bodies_preserved": self.inlinable_bodies_preserved,
            "opaque_rewrites": self.opaque_rewrites,
            "static_storage_rewrites": self.static_storage_rewrites,
            "self_qualifiers_removed": self.self_qualifiers_removed,
            "synthesized_projections_omitted": self.synthesized_projections_omitted,
            "overridden": self.overridden,
            "synthesized_witnesses": self.synthesized_witnesses,
            "wrapper_attributes_removed": self.wrapper_attributes_removed,
            "convenience_init_rewrites": self.convenience_init_rewrites,
            "duplicate_witnesses_omitted": self.duplicate_witnesses_omitted,
            "synthesized_inits": self.synthesized_inits,
            "incompatible_conformances_omitted": self.incompatible_conformances_omitted,
        }


class Generator:
    """Turns one retargeted interface into one generated Swift file."""

    def __init__(self, spec: "ModuleSpec", implemented: set[str]) -> None:
        self.spec = spec
        self.module = spec.interface_module
        self.implemented = implemented
        self.entries: list[BodyEntry] = []
        #: (category, symbol) for every engine seam found (stub, inlined or overridden)
        self.seams: list[tuple[str, str]] = []
        self.override_hits: set[str] = set()
        self.omitted_projections: list[str] = []
        self.omitted_typealiases: set[int] = set()
        self.init_hits: set[str] = set()
        self.stats = ModuleStats()
        self.opaque_typealias_members: dict[str, list[Member]] = {}
        self.opaque_typealias_paths: set[str] = set()
        self.toplevel_types: dict[str, str] = {}
        self.edits: list[Edit] = []
        self.body = ""
        self.root: Container | None = None

    # -- input ------------------------------------------------------------
    def interface_path(self) -> str:
        directory = os.path.join(GEN_DIR, f"{self.module}.swiftmodule")
        for name in (
            f"{TARGET}.swiftinterface",
            "aarch64-unknown-linux-android.swiftinterface",
            "aarch64.swiftinterface",
        ):
            path = os.path.join(directory, name)
            if os.path.exists(path):
                return path
        raise SystemExit(
            f"error: no retargeted interface for {self.module} under {directory}.\n"
            "       Run scripts/port/build-port-sdk.sh first."
        )

    def load(self) -> str:
        path = self.interface_path()
        interface = ""
        # build-port-sdk.sh may be rewriting the interface concurrently (it deletes and
        # recreates the directory); retry briefly instead of failing on a transient gap.
        for attempt in range(10):
            try:
                with open(path, encoding="utf-8") as handle:
                    interface = handle.read()
            except FileNotFoundError:
                interface = ""
            # A complete interface ends with the closing brace of its last declaration;
            # build-port-sdk.sh rewrites these files in place, so a mid-rebuild snapshot can
            # be truncated. Retry rather than generating from a partial interface.
            if len(interface) > 1024 and interface.rstrip().endswith("}"):
                break
            time.sleep(0.3)
        if len(interface) <= 1024 or not interface.rstrip().endswith("}"):
            raise SystemExit(
                f"error: {path} is missing or truncated (is scripts/port/build-port-sdk.sh "
                "still running?); rerun it and retry"
            )
        lines = interface.splitlines(keepends=True)
        body_offset = 0
        for index, line in enumerate(lines):
            if re.match(r"^(@\w+\s+)?import\s", line):
                body_offset = sum(len(previous) for previous in lines[:index])
                break
        else:
            raise SystemExit(f"error: no import block found in {path}")
        return interface[body_offset:]

    # -- analysis ---------------------------------------------------------
    #: Names of protocols Apple already declares `Never` conformance to.
    never_conformances: set[str] = set()

    def collect_never_conformances(self, root: Container) -> None:
        def visit(container: Container) -> None:
            if container.kind == "extension" and container.path in ("Never",):
                for conformance in container.conformances:
                    self.never_conformances.add(conformance.split(".")[-1])
            for child in container.children:
                visit(child)

        visit(root)

    def collect_opaque_typealiases(self, root: Container) -> None:
        def visit(container: Container) -> None:
            for member in container.members:
                if member.kind == "typealias" and member.opaque_typealias_span is not None:
                    self.opaque_typealias_paths.add(container.path)
                    self.opaque_typealias_members.setdefault(container.path, []).append(member)
            for child in container.children:
                visit(child)

        visit(root)

    # -- edit helpers -----------------------------------------------------
    def indent_at(self, offset: int) -> str:
        line_start = self.body.rfind("\n", 0, offset) + 1
        match = re.match(r"[ \t]*", self.body[line_start:offset])
        return match.group(0) if match else ""

    def add_comment(self, offset: int, message: str) -> None:
        indent = self.indent_at(offset)
        self.edits.append(Edit(offset, offset, f"{indent}// port: {message}\n"))

    def symbol_for(self, container: Container, member: Member) -> str:
        prefix = self.module
        if container.path:
            prefix = f"{self.module}.{container.path}"
        return f"{prefix}.{member.name}"

    def span_text(self, span: tuple[int, int]) -> str:
        return self.body[span[0]:span[1]]

    def record_body(self, symbol: str, kind: str, inlined: bool) -> None:
        self.entries.append(BodyEntry(symbol, self.module, kind, inlined))

    def note_seam(self, member: Member, symbol: str) -> None:
        self.note_seam_name(member.name, symbol)

    def note_seam_name(self, name: str, symbol: str) -> None:
        category: str | None = None
        if name == "body":
            category = "body"
        elif name.startswith("_makeView("):
            category = "_makeView(view:inputs:)"
        elif name.startswith("_makeViewList("):
            category = "_makeViewList(view:inputs:)"
        elif name.startswith("_viewListCount("):
            category = "_viewListCount(inputs:)"
        if category:
            self.seams.append((category, symbol))

    # -- edit generation --------------------------------------------------
    def generate_edits(self, shared: "SharedModel") -> None:
        assert self.root is not None
        self.shared = shared

        def visit(container: Container, protocol_requirements: bool) -> None:
            for member in container.members:
                if member.kind == "import":
                    continue
                self.stats.declarations += 1
                symbol = self.symbol_for(container, member)
                self.note_seam(member, symbol)
                # R13: a result-builder attribute on a protocol requirement is applied to every
                # witness's body; the stub's `Never` cannot satisfy the builder's constraints
                # (`Never.TabValue == Self.TabValue`), so the convenience attribute is dropped
                # from the requirement. Signature and call sites are unchanged.
                if container.kind == "protocol" and not self.has_real_body(member):
                    self.strip_builder_attributes(member)
                # R10: a duplicate associated-type witness from Apple's other module interface.
                if id(member) in shared.omitted:
                    self.add_comment(
                        member.start,
                        "omitted: a single-module port can only keep one witness per "
                        "associated type (R10)",
                    )
                    self.edits.append(Edit(member.start, member.end, ""))
                    self.stats.duplicate_witnesses_omitted += 1
                    continue
                # A parameterless initializer in an extension duplicates the implicit memberwise
                # `init()` of a value type; the port declares one public stub instead (R11).
                if (
                    member.kind == "init"
                    and member.name == "init()"
                    and container.kind == "extension"
                    and (
                        container.path in shared.synth_inits
                        or container.path in shared.no_stored_props
                    )
                ):
                    self.add_comment(
                        member.start,
                        "duplicate parameterless initializer; the port declares one public "
                        "`init()` in the type (R11)",
                    )
                    self.edits.append(Edit(member.start, member.end, ""))
                    self.stats.duplicate_witnesses_omitted += 1
                    continue

                # R6: the engine implements this symbol; omit the declaration entirely.
                if symbol in self.implemented:
                    self.apply_override(container, member, symbol)
                    continue
                # R5: `$`-prefixed projections are synthesised by the compiler, not declarable.
                if member.kind in ("var", "let") and member.name.startswith("$"):
                    self.apply_projection_omission(member, symbol)
                    continue
                # R3: `@_opaqueReturnTypeOf` typealiases are resolved against Apple's binary.
                if member.kind == "typealias" and member.opaque_typealias_span is not None:
                    span = member.opaque_typealias_span
                    self.add_comment(
                        member.start,
                        "@_opaqueReturnTypeOf resolved against Apple's binary; "
                        "the port has no opaque type to name, so Body is Never (R3)",
                    )
                    self.edits.append(Edit(span[0], span[1], "Swift.Never"))
                    self.stats.opaque_rewrites += 1
                if protocol_requirements:
                    continue  # protocol requirements are legal without bodies
                if member.kind in ("func", "init", "subscript"):
                    self.handle_callable(container, member, symbol)
                elif member.kind in ("var", "let"):
                    self.handle_property(container, member, symbol)
                elif member.kind == "deinit":
                    if not member.has_body:
                        self.edits.append(Edit(member.end, member.end, " {}"))
                        self.stats.bodies_injected += 1
                        self.record_body(symbol, "deinit", False)
                    else:
                        self.stats.bodies_preserved += 1
                elif member.has_body:
                    self.stats.bodies_preserved += 1
                    if member.inlinable:
                        self.stats.inlinable_bodies_preserved += 1
                        self.record_body(symbol, member.kind, True)
            for child in container.children:
                self.stats.types += 1
                visit(child, child.kind == "protocol")
            if container.kind in ("struct", "class", "enum", "actor"):
                entry = shared.synth_inits.get(container.path)
                symbol = f"{self.module}.{container.path}.init()"
                if entry is not None and entry[1] is container and symbol not in self.init_hits:
                    self.init_hits.add(symbol)
                    indent = self.indent_at(container.end - 1) if container.end else ""
                    override = "override " if container.path in shared.override_inits else ""
                    self.edits.append(
                        Edit(
                            container.end - 1, container.end - 1,
                            f"{indent}  // port: public parameterless initializer (R11); Apple's "
                            f"implicit memberswise initializer is internal\n"
                            f"{indent}  public {override}init() {{ _suiUnimplemented(\"{symbol}\") }}\n",
                        )
                    )
                    self.stats.synthesized_inits += 1
                    self.stats.bodies_injected += 1
                    self.record_body(symbol, "init", False)

        visit(self.root, False)
        self.synthesize_witnesses(shared)
        for block in shared.synthetic_extensions.get(self.spec.file_stem, []):
            self.edits.append(Edit(len(self.body), len(self.body), block))
        missing = sorted(self.implemented - self.override_hits)
        if missing:
            raise GenerationError(
                "port-impl/implemented.txt lists symbols that are not bodyless declarations in "
                f"the {self.module} interface (check spelling against build/port-sdk/"
                "injected-bodies.json):\n  " + "\n  ".join(missing)
            )

    def apply_override(self, container: Container, member: Member, symbol: str) -> None:
        """R6: omit a declaration the engine implements in `Sources/SwiftUI/Engine/Implemented/`."""
        if (
            member.kind in ("var", "let")
            and not member.accessors
            and member.result_type_span is not None
            and not member.static
            and not member.has_body
        ):
            raise GenerationError(
                f"{symbol} is a stored instance property; it cannot be declared in an extension "
                "and therefore cannot be overridden. Engine storage must be supplied by a "
                "generated declaration (R6)."
            )
        if member.kind in ("var", "let") and member.result_type_span is not None \
                and "some" in self.span_text(member.result_type_span):
            # The witness's associated type spelling (`typealias Body = Never`) would conflict
            # with the engine's real body; drop it so Swift infers `Body` from the extension
            # witness (same module).
            for typealias_member in self.opaque_typealias_members.get(container.path, []):
                if id(typealias_member) in self.omitted_typealiases:
                    continue
                self.omitted_typealiases.add(id(typealias_member))
                self.add_comment(
                    typealias_member.start,
                    f"associated type spelling omitted together with {symbol} (R6): the engine "
                    "supplies the real witness, so Body is inferred from it",
                )
                self.edits.append(Edit(typealias_member.start, typealias_member.end, ""))
        self.add_comment(
            member.start,
            f"implemented by the engine (port-impl/implemented.txt); declaration omitted (R6)",
        )
        self.edits.append(Edit(member.start, member.end, ""))
        self.stats.overridden += 1
        self.override_hits.add(symbol)

    def apply_projection_omission(self, member: Member, symbol: str) -> None:
        """R5: drop a `$`-named projected value; Swift synthesises those from property wrappers."""
        self.add_comment(
            member.start,
            f"'{member.name}' is an implicitly-synthesised property-wrapper projection; a "
            "'$'-prefixed declaration cannot be written in source (R5), omitted",
        )
        self.edits.append(Edit(member.start, member.end, ""))
        self.stats.synthesized_projections_omitted += 1
        self.omitted_projections.append(symbol)

    @staticmethod
    def has_real_body(member: Member) -> bool:
        """True when the member carries Apple's own code (an `@inlinable` body)."""
        if member.has_body and not member.accessors:
            return True
        return any(accessor.has_body for accessor in member.accessors)

    def strip_builder_attributes(self, member: Member) -> None:
        """Remove result-builder attributes from a declaration that is about to get a stub body.

        A `.swiftinterface` spells a builder-returning requirement as
        ``@TabContentBuilder<Self.TabValue> var body: Self.Body { get }``. When the port injects
        ``{ get { _suiUnimplemented(...) } }``, the result-builder transform applies to that stub
        expression and requires `Never` to satisfy the builder's generic constraints
        (`Never.TabValue == Self.TabValue`), which is not true. The attribute is a client-side
        convenience; without it the declaration keeps the same signature, so it is stripped from
        stubbed declarations only (never from Apple's real `@inlinable` bodies). R13.
        """
        if not self.shared or not self.shared.builder_names:
            return
        if member.keyword_span is None:
            return
        region_start = member.start
        region_end = member.keyword_span[0]
        if region_end <= region_start:
            return
        tokens = tokenize(self.body[region_start:region_end])
        index = 0
        while index < len(tokens):
            if tokens[index].text != "@":
                index += 1
                continue
            start = index
            index += 1
            if index >= len(tokens):
                break
            name = tokens[index].text
            index += 1
            while index < len(tokens):
                if tokens[index].text == "." and index + 1 < len(tokens) and tokens[index + 1].kind == "id":
                    name = tokens[index + 1].text
                    index += 2
                    continue
                if (
                    tokens[index].text == ":"
                    and index + 2 < len(tokens)
                    and tokens[index + 1].text == ":"
                    and tokens[index + 2].kind == "id"
                ):
                    name = tokens[index + 2].text
                    index += 3
                    continue
                break
            if index < len(tokens) and tokens[index].text == "<":
                index = skip_tokens(tokens, index)
            if index < len(tokens) and tokens[index].text == "(":
                index = skip_tokens(tokens, index)
            if name in self.shared.builder_names:
                self.edits.append(
                    Edit(
                        region_start + tokens[start].start,
                        region_start + tokens[index - 1].end,
                        "",
                    )
                )

    def inject_accessors(self, member: Member, symbol: str, kind: str) -> None:
        """Inject bodies into bodyless accessors of a property/subscript accessor block."""
        injected = 0
        for accessor in member.accessors:
            if accessor.has_body:
                continue
            self.edits.append(
                Edit(accessor.keyword_end, accessor.keyword_end,
                     f' {{ _suiUnimplemented("{symbol}") }}')
            )
            injected += 1
        if injected:
            self.stats.bodies_injected += injected
            self.record_body(symbol, kind, False)
        preserved = [accessor for accessor in member.accessors if accessor.has_body]
        if preserved:
            self.stats.bodies_preserved += len(preserved)
            if member.inlinable or any(accessor.inlinable for accessor in preserved):
                self.stats.inlinable_bodies_preserved += len(preserved)
                self.record_body(symbol, kind, True)

    def maybe_rewrite_opaque(self, container: Container, member: Member, message: str) -> None:
        if member.result_type_span is None:
            return
        # A declaration with a real (Apple `@inlinable`) body infers its own opaque type; never
        # rewrite it, or the body would no longer match its declared return type.
        if self.has_real_body(member):
            return
        span_text = self.span_text(member.result_type_span)
        if "some" not in span_text:
            return
        # `some P<Args>` (a protocol with primary associated types) cannot be satisfied by the
        # stub's `Never`: `Never`'s conformance would bind the associated types to `Never`, which
        # does not match `P<Args>` (e.g. `some TabContent<TabValue>` requires `Never.TabValue ==
        # TabValue`). Drop the constraint by declaring the result `Swift.Never` instead.
        generic_opaque = "<" in span_text
        if not generic_opaque and not self.opaque_needs_never(member.result_type_span, container):
            return
        span = member.result_type_span
        replacement = "Swift.Never"
        if generic_opaque:
            match = re.match(r"\s*some\s+([^<]+)<(.+)>\s*$", span_text, re.S)
            base = ""
            argument = ""
            if match:
                qualified = match.group(1).strip().replace("::", ".")
                base = qualified.split(".")[-1]
                argument = match.group(2).strip()
            if base == "IteratorProtocol" and argument:
                # `some IteratorProtocol<Element>`: no local type can be invented for it, but the
                # stdlib has an always-empty iterator with the right element type.
                replacement = (
                    f"Swift.IndexingIterator<Swift.EmptyCollection<{argument}>>"
                )
            elif base in (
                "Sequence", "Collection", "BidirectionalCollection",
                "RandomAccessCollection", "MutableCollection",
            ) and argument:
                replacement = f"Swift.EmptyCollection<{argument}>"
            elif container.kind != "module":
                # `some P<Args>` where the type itself conforms to `P<Args>` (e.g. `Body`):
                # `Self` satisfies the primary-associated-type equality by construction, and
                # `Never` converts to `Self`.
                replacement = "Self"
        self.add_comment(member.start, message)
        self.edits.append(Edit(span[0], span[1], replacement))
        self.stats.opaque_rewrites += 1

    def opaque_needs_never(self, span: tuple[int, int], container: Container) -> bool:
        base = base_protocol_name(self.span_text(span))
        if not base:
            return True
        if container.path in self.opaque_typealias_paths:
            return True
        if base in self.never_conformances or base in STDLIB_NEVER_CONFORMANCES:
            return False
        return True

    def handle_callable(self, container: Container, member: Member, symbol: str) -> None:
        if member.kind == "init" and container.kind == "extension" and not member.has_body:
            # Swift forbids *designated* initializers in extensions of Swift classes. Apple's
            # interfaces declare `init` in extensions of ObjC-imported classes (ObjC interop
            # allows it); on the port those classes are plain Swift classes in shims, so the
            # initializer is emitted as `convenience init` (R9).
            kind = self.shared.type_kind(container.path) if self.shared else None
            if kind == "class" and not any(
                value == "convenience" for kind_name, value in member.prefix if kind_name == "mod"
            ):
                self.add_comment(
                    member.start,
                    "initializer declared in an extension of a class; emitted as "
                    "`convenience init` (R9)",
                )
                if member.keyword_span is not None:
                    self.edits.append(Edit(member.keyword_span[0], member.keyword_span[0], "convenience "))
                self.stats.convenience_init_rewrites += 1
        if member.accessors:
            # A subscript with an accessor block (`{ get set }`), not a function body.
            self.strip_builder_attributes(member)
            self.maybe_rewrite_opaque(
                container, member,
                "opaque result type is not expressible in source; declared as Never (R3)",
            )
            self.inject_accessors(member, symbol, "subscript")
            return
        if member.has_body:
            self.stats.bodies_preserved += 1
            if member.inlinable:
                self.stats.inlinable_bodies_preserved += 1
                self.record_body(symbol, member.kind, True)
            return
        self.strip_builder_attributes(member)
        self.maybe_rewrite_opaque(
            container, member,
            "opaque result type is not expressible in source; declared as Never (R3)",
        )
        self.edits.append(
            Edit(member.end, member.end, f' {{ _suiUnimplemented("{symbol}") }}')
        )
        self.stats.bodies_injected += 1
        self.record_body(symbol, member.kind, False)

    def handle_property(self, container: Container, member: Member, symbol: str) -> None:
        # R2: stored static storage / stored properties in extensions cannot compile as source.
        stored_static = (
            member.static and not member.accessors and member.result_type_span is not None
            and not member.has_body
        )
        stored_in_extension = (
            container.kind in ("extension", "module") and not member.accessors
            and member.result_type_span is not None and not self.has_real_body(member)
        )
        if stored_static or stored_in_extension:
            reason = (
                "interface describes static storage (no initializer); "
                "emitted as read-only computed property (R2)"
                if stored_static
                else "extensions cannot declare stored properties; "
                     "emitted as read-only computed property (R2)"
            )
            self.add_comment(member.start, reason)
            if member.kind == "let" and member.keyword_span is not None:
                span = member.keyword_span
                self.edits.append(Edit(span[0], span[1], "var"))
            self.edits.append(
                Edit(
                    member.end, member.end,
                    f' {{ get {{ _suiUnimplemented("{symbol}") }} }}',
                )
            )
            self.stats.static_storage_rewrites += 1
            self.stats.bodies_injected += 1
            self.record_body(symbol, "var", False)
            return

        self.strip_builder_attributes(member)
        self.maybe_rewrite_opaque(
            container, member,
            "opaque type is a witness for a declared associated type / has no Never "
            "conformance; declared as Never (R3)",
        )

        if member.accessors:
            self.inject_accessors(member, symbol, "var")
            return

        # A stored instance property with no initializer is legal Swift: it is initialised by
        # the type's initialisers, whose bodies never return thanks to `_suiUnimplemented`.
        if member.has_body:
            self.stats.bodies_preserved += 1
            if member.inlinable:
                self.stats.inlinable_bodies_preserved += 1
                self.record_body(symbol, "var", True)

    # -- synthesized conformance witnesses (R7) ----------------------------
    def synthesize_witnesses(self, shared: "SharedModel") -> None:
        """Add witnesses Apple implements with internal (interface-invisible) members.

        A `.swiftinterface` only prints `public`, `package` and `@usableFromInline internal`
        members. Apple implements many conformance witnesses as plain `internal` members
        (e.g. `ZStack.body`, `ZStackLayout.sizeThatFits(proposal:subviews:cache:)`), so they are
        absent from the interface and the type no longer conforms when that interface is
        compiled as source. This pass copies each missing requirement out of the local protocol
        declaration, gives it an injected body, and emits it as `public` (outside library
        evolution Swift requires the witness of a public protocol to be public).
        """
        assert self.root is not None

        def visit(container: Container) -> None:
            if container.kind not in ("module", "protocol") and container.conformances:
                self.synthesize_for_container(container, shared)
            for child in container.children:
                visit(child)

        visit(self.root)

    def synthesize_for_container(self, container: Container, shared: "SharedModel") -> None:
        path = container.path
        substitutions: dict[str, str] = {}
        for member in container.members:
            if member.kind == "typealias" and member.keyword_span is not None:
                text = self.body[member.start:member.end]
                equals = text.find("=")
                if equals >= 0:
                    substitutions[member.name] = text[equals + 1:].strip()
        closing_indent = self.indent_at(container.end - 1) if container.end else ""
        body_indent = closing_indent + "  "

        for conformance in container.conformances:
            protocol_path = shared.resolve(conformance)
            if protocol_path is None:
                continue  # declared in another module; its witnesses are that module's problem
            merged = shared.substitutions_for(protocol_path, substitutions)
            for requirement in shared.requirements(protocol_path):
                if requirement.name in shared.implemented.get(path, set()):
                    continue
                if requirement.name in shared.synthesized.get(path, set()):
                    continue
                if shared.has_default(protocol_path, requirement.name):
                    continue
                symbol = f"{self.module}.{path}.{requirement.name}"
                self.note_seam_name(requirement.name, symbol)
                if symbol in self.implemented:
                    shared.synthesized.setdefault(path, set()).add(requirement.name)
                    self.override_hits.add(symbol)
                    self.stats.overridden += 1
                    self.add_comment(
                        container.end - 1,
                        f"{symbol} is implemented by the engine (port-impl/implemented.txt); "
                        "witness not synthesized (R6)",
                    )
                    continue
                declaration = build_witness(requirement, merged, symbol)
                if declaration is None:
                    shared.unsupported.append(f"{symbol} (requirement of {protocol_path})")
                    continue
                block = (
                    f"{body_indent}// port: synthesized witness for {protocol_path} (R7); "
                    "Apple implements it with an internal member\n"
                    f"{body_indent}{declaration}\n"
                )
                self.edits.append(Edit(container.end - 1, container.end - 1, block))
                shared.synthesized.setdefault(path, set()).add(requirement.name)
                self.stats.synthesized_witnesses += 1
                self.stats.bodies_injected += 1
                kind = "var" if requirement.kind in ("var", "let") else requirement.kind
                self.record_body(symbol, kind, False)

    # -- module qualification (R1) ----------------------------------------
    def requalify_modules(self, text: str) -> str:
        """Rewrite Apple module qualifiers for the single-module port.

        Two distinct spellings occur in the interfaces:

        * a *leading* module qualifier: ``SwiftUICore::View``, ``SwiftUICore.View`` and
          ``SwiftUI.View`` -> ``SwiftUI.View`` (self-qualification inside the module being
          compiled). The qualifier is kept rather than dropped: dropping it lets a generic
          parameter or a nested type shadow the intended type
          (`extension MenuBarExtra where Label == Label<Text, Image>` resolved `Label` to the
          generic parameter and failed with "cannot specialize non-generic type 'Label'").
        * a *nested* module qualifier: the interface printer writes member lookups as
          ``SwiftUICore::Image.SwiftUICore::ResizingMode``; there the second qualifier is a
          disambiguation aid, not part of the type name, so it is dropped:
          ``SwiftUI.Image.ResizingMode``. Renaming it instead yields the invalid
          ``SwiftUI::Image.SwiftUI::ResizingMode`` (``SwiftUI::ResizingMode`` is not a type).
        """
        names = set(self.spec.requalify) | {COMPILED_MODULE}
        if not names:
            return text
        tokens = tokenize(text)
        edits: list[Edit] = []
        rewritten = 0
        index = 0
        while index < len(tokens):
            token = tokens[index]
            if token.kind == "id" and token.text in names:
                separator_end: int | None = None
                is_angle_separator = False
                if (
                    index + 2 < len(tokens)
                    and tokens[index + 1].text == ":"
                    and tokens[index + 2].text == ":"
                    and tokens[index + 1].end == tokens[index + 2].start
                ):
                    separator_end = tokens[index + 2].end
                    is_angle_separator = True
                elif (
                    index + 2 < len(tokens)
                    and tokens[index + 1].text == "."
                    and tokens[index + 2].kind == "id"
                ):
                    separator_end = tokens[index + 1].end
                if separator_end is not None:
                    # Find the previous significant character in the original text.
                    cursor = token.start
                    while cursor > 0 and text[cursor - 1] in " \t\r\n":
                        cursor -= 1
                    nested = cursor > 0 and text[cursor - 1] == "."
                    if nested:
                        edits.append(Edit(token.start, separator_end, ""))
                    elif token.text != COMPILED_MODULE:
                        edits.append(Edit(token.start, token.end, COMPILED_MODULE))
                    rewritten += 1
                    index += 3 if is_angle_separator else 2
                    continue
            index += 1
        self.stats.self_qualifiers_removed += rewritten
        if not edits:
            return text
        return apply_edits(text, edits)

    def drop_imports(self, text: str) -> str:
        """Drop prelude imports of modules that are local declarations in the port module."""
        if not self.spec.drop_imports:
            return text
        lines = text.splitlines(keepends=True)
        kept: list[str] = []
        in_prelude = True
        for line in lines:
            if in_prelude:
                match = re.match(r"^(@\w+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", line.rstrip("\n"))
                if match:
                    if match.group(2) in self.spec.drop_imports:
                        continue
                    kept.append(line)
                    continue
                if line.strip() == "":
                    kept.append(line)
                    continue
                in_prelude = False
            kept.append(line)
        return "".join(kept)

    # -- rendering ---------------------------------------------------------
    def banner(self) -> str:
        rules = [
            "//   R1  `Module::Foo` / `Module.Foo` qualifiers for the two Apple modules are",
            "//       requalified to the compiled module (`SwiftUI::Foo` / `SwiftUI.Foo`); nested",
            "//       duplicate qualifiers (`.SwiftUICore::Foo`) are dropped. `@_exported import",
            "//       SwiftUICore` is dropped (both interfaces are one module here). Keeping the",
            "//       leading qualifier avoids generic-parameter shadowing (`Label`).",
            "//   R2  stored static `let x: T` -> computed read-only `static var x: T { get { ... } }`",
            "//       (interface-only spelling of Apple's binary storage; no initializer in source).",
            "//       Stored properties in extensions and at module scope become computed too.",
            "//   R3  `@_opaqueReturnTypeOf(...)` typealiases and opaque results that cannot be",
            "//       expressed in source -> `Swift.Never`; `some P<Args>` (primary associated",
            "//       types) -> `Self`, which satisfies `Self.X == Self.Body.X`.",
            "//   R4  Apple-compiler `#if` feature conditions are evaluated for the pinned toolchain;",
            "//       dead fallback branches are preserved verbatim but not injected into.",
            "//   R5  `$`-prefixed property-wrapper projections are omitted: Swift synthesises them,",
            "//       and the `$` prefix cannot be declared in source.",
            "//   R6  declarations listed in `port-impl/implemented.txt` are omitted so the engine",
            "//       can implement them in an extension in the same module (witnesses supported).",
            "//   R7  conformance witnesses Apple implements `internal` are synthesised from the",
            "//       protocol declarations (same-module conformances).",
            "//   R8  `@propertyWrapper` / `@_projectedValueProperty` attributes are removed: the",
            "//       port does not use Apple's wrappers, and the compiler recurses through them.",
            "//   R9  designated initializers Apple declares in extensions of classes become",
            "//       `convenience init` (Swift forbids the former in source).",
            "//   R10 duplicate associated-type witnesses from Apple's two interfaces are unified:",
            "//       one unconditional `Body`/`body` per type (`Body = Self` when the halves",
            "//       disagree); duplicate witnesses are omitted and listed in the manifest.",
            "//   R11 value types with no stored properties get one public `init()` stub (the",
            "//       implicit memberwise initializer is internal and cannot be used in default",
            "//       arguments); duplicate extension `init()`s are omitted.",
            "//   R13 result-builder attributes are removed from declarations that receive a stub",
            "//       body: the builder would transform the `Never`-typed stub and fail.",
            "//       (There is no R12: the `never`-conformance pass it named was removed because",
            "//       `Body = Self` made it unnecessary and `Never` cannot satisfy constrained",
            "//       associated types such as `Scope : AttributeScope`.)",
        ]
        lines = [
            f"// {self.spec.file_stem}.swift — GENERATED FILE, DO NOT EDIT BY HAND.",
            "//",
            "// Source: Apple's own module interface",
            f"//   <iOS Simulator SDK>/{self.module}.framework/Modules/{self.module}.swiftmodule/"
            "arm64-apple-ios-simulator.swiftinterface",
            f"// retargeted to {TARGET} by scripts/port/build-port-sdk.sh, then turned into",
            "// compilable Swift by scripts/port/inject_bodies.py. Regenerate with",
            "// `scripts/port/generate.sh`; see docs/PORT-BODIES.md.",
            "//",
            f"// Both generated files compile into one module (`{COMPILED_MODULE}`): Apple's",
            "// SwiftUI/SwiftUICore split is their binary layout, not the port's module layout.",
            "//",
            "// Every declaration below is Apple's text byte-for-byte. The port adds",
            "//   * `{ _suiUnimplemented(\"<symbol>\") }` bodies for declarations Apple ships bodyless,",
            "//   * bodies for bodyless property accessors,",
            "//   * `{}` for bodyless `deinit`s,",
            f"// and applies the documented rewrite rules (details in docs/PORT-BODIES.md):",
            "//",
            *rules,
            "//",
            "// `@inlinable` bodies are Apple's real code and are never modified. The",
            "// `_suiUnimplemented` seam is defined by Sources/SwiftUI/Engine/PortRuntime.swift,",
            "// which is compiled into this same module.",
            "",
        ]
        return "\n".join(lines)

    def parse(self) -> None:
        """Load and parse the interface, and collect the facts the edit pass needs."""
        body = self.load()
        parser = Parser(body, preprocess_conditionals(body))
        root = parser.parse()
        self.root = root
        self.body = body
        self.toplevel_types = {
            child.path: child.kind
            for child in root.children
            if child.kind in ("struct", "class", "enum", "protocol", "actor")
        }
        self.collect_never_conformances(root)
        self.collect_opaque_typealiases(root)

    def render_source(self, attribute_names: set[str] | None = None) -> str:
        edited = apply_edits(self.body, self.edits)
        edited = self.requalify_modules(edited)
        edited = self.drop_imports(edited)
        if attribute_names:
            edited, removed = strip_attribute_prefixes(edited, attribute_names)
            self.stats.wrapper_attributes_removed += removed
        return "".join([self.banner(), edited])

    def manifest(self) -> dict:
        unique: dict[tuple[str, str, bool], BodyEntry] = {}
        for entry in self.entries:
            unique.setdefault((entry.symbol, entry.kind, entry.inlined), entry)
        bodies = [
            {
                "symbol": entry.symbol,
                "module": entry.module,
                "kind": entry.kind,
                "inlined": entry.inlined,
            }
            for entry in sorted(unique.values(), key=lambda e: (e.module, e.symbol, e.kind, e.inlined))
        ]
        return {
            "file": f"{self.spec.file_stem}.swift",
            "module": self.module,
            "stats": self.stats.as_dict(),
            "bodies": bodies,
            "seams": [{"category": category, "symbol": symbol} for category, symbol in self.seams],
            "overridden": sorted(self.override_hits),
            "synthesized_projections_omitted": sorted(self.omitted_projections),
        }


# ---------------------------------------------------------------------------
# Cross-file model for synthesized witnesses (R7)
# ---------------------------------------------------------------------------


def load_shim_type_kinds() -> dict[str, str]:
    """Scan `port-shims/**/*.swift` for the kind of each shimmed foreign type.

    Needed for R9 (initializers in extensions): whether the extended type is a class is a
    property of the shim, not of Apple's interface. Unknown names return no kind.
    """
    import glob

    kinds: dict[str, str] = {}
    pattern = re.compile(
        r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |open |final |internal |package )*"
        r"(struct|class|enum|actor)\s+([A-Za-z_]\w*)",
        re.M,
    )
    for path in sorted(glob.glob(os.path.join(ROOT, "port-shims", "*", "*.swift"))):
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except OSError:
            continue
        for match in pattern.finditer(text):
            kinds.setdefault(match.group(2), match.group(1))
    return kinds


@dataclass
class Requirement:
    """One protocol requirement, in the spelling the protocol declaration used."""

    kind: str
    name: str
    text: str
    accessors: list[Accessor]
    keyword_offset: int
    block_offset: int | None
    modifiers: list[str]


def walk_containers(container: Container):
    yield container
    for child in container.children:
        yield from walk_containers(child)


def build_witness(requirement: Requirement, substitutions: dict[str, str], symbol: str) -> str | None:
    """Render a witness declaration for ``requirement`` with an injected body.

    ``Self.X`` is replaced by the type's own ``typealias X`` (or the protocol's associated-type
    default). Unknown associated types become `Swift.Never`, which is the port's bottom type.
    Returns ``None`` for requirements the port cannot spell (e.g. exotic accessor sets).
    """
    text = requirement.text
    end = requirement.block_offset if requirement.block_offset is not None else len(text)
    signature = text[requirement.keyword_offset:end].rstrip()

    def replace_associated(match: re.Match) -> str:
        name = match.group(1)
        if name in substitutions:
            return substitutions[name]
        if name == "Iterator":
            # `Sequence`'s Iterator has no witness in the interface; the port provides a concrete
            # placeholder (Engine/PortRuntime.swift) instead of the uninhabited `Never`, which
            # does not conform to `IteratorProtocol`.
            return "SwiftUI._PortIterator"
        return "Swift.Never"

    signature = re.sub(r"\bSelf\.(\w+)", replace_associated, signature)
    kept = [modifier for modifier in requirement.modifiers if modifier in WITNESS_MODIFIERS]
    head = "public " + "".join(modifier + " " for modifier in kept)
    if requirement.kind in ("func", "init"):
        return f'{head}{signature} {{ _suiUnimplemented("{symbol}") }}'
    keywords = [accessor.keyword for accessor in requirement.accessors]
    if not keywords or any(keyword not in ("get", "set", "_modify") for keyword in keywords):
        return None
    accessor_bodies = "".join(
        f' {keyword} {{ _suiUnimplemented("{symbol}") }}' for keyword in keywords
    )
    return f"{head}{signature} {{{accessor_bodies} }}"


#: Conformances that cannot be expressed in a single Swift module. Apple ships each half in a
#: different module (`SwiftUI` / `SwiftUICore`) and relies on per-module associated-type witness
#: shadowing; merged into one module there is exactly one witness per associated type, and these
#: protocols require witnesses that are mutually incompatible with the type's other conformances.
#: Omitting the conformance clause is the only way to keep the rest of the declaration intact;
#: every omission is recorded in the manifest (`incompatible_conformances_omitted`) and in
#: docs/PORT-BODIES.md. Nothing else is dropped.
INCOMPATIBLE_CONFORMANCES: tuple[dict[str, str], ...] = (
    {
        "type": "Optional",
        "protocol": "SliderTickContent",
        "declared_in": "SwiftUI",
        "conflicting_witness": (
            "Body: Swift.RandomAccessCollection (with Body.Element == SliderTick<Self.Value>) "
            "required by SliderTickContent vs Body: SwiftUI.View required by View "
            "(and Body: SwiftUI.TabContent required by TabContent)"
        ),
    },
    {
        "type": "_ConditionalContent",
        "protocol": "SliderTickContent",
        "declared_in": "SwiftUI",
        "conflicting_witness": (
            "Body: Swift.RandomAccessCollection (with Body.Element == SliderTick<Self.Value>) "
            "required by SliderTickContent vs Body: SwiftUI.View required by View; the shipped "
            "interface half is also internally inconsistent (typealias Body = TrueContent but "
            "body: TrueContent.Body)"
        ),
    },
    {
        "type": "GestureStateGesture",
        "protocol": "Gesture",
        "declared_in": "SwiftUI",
        "conflicting_witness": (
            "public stored property body: (Value, inout State, inout Transaction) -> Void "
            "shadows Gesture's requirement body: Self.Body (Never); the stored property cannot be "
            "dropped because Apple's @inlinable init assigns it"
        ),
    },
)


class SharedModel:
    """Cross-file facts used to synthesise missing conformance witnesses (R7).

    Both generated files are one module, so requirements declared in either file can be
    witnessed by types declared in either file. This model indexes protocols, their
    inheritance, protocol-extension default implementations and the members every type already
    has (in declarations *and* extensions).
    """

    def __init__(self, generators: list["Generator"]) -> None:
        self.generators = generators
        self.protocols: dict[str, tuple[Container, str, str]] = {}
        self.protocol_by_name: dict[str, list[str]] = {}
        self.associated_defaults: dict[str, dict[str, str]] = {}
        self.inheritance: dict[str, list[str]] = {}
        self.defaults: dict[str, set[str]] = {}
        self.implemented: dict[str, set[str]] = {}
        self.synthesized: dict[str, set[str]] = {}
        self.unsupported: list[str] = []
        self.attribute_names: set[str] = {"_projectedValueProperty", "propertyWrapper"}
        self.type_kinds: dict[str, str] = {}
        self.shim_type_kinds: dict[str, str] = {}
        self._requirements: dict[str, list[Requirement]] = {}
        self._assoc_names: dict[str, set[str]] = {}
        self.chosen_assoc: dict[tuple[str, str], str] = {}
        self.omitted: set[int] = set()
        self.omitted_keys: set[tuple[str, int]] = set()
        self.omissions: list[tuple["Generator", Member, str]] = []
        self.synth_inits: dict[str, tuple["Generator", Container]] = {}
        self.synth_body: dict[str, str] = {}
        #: Paths whose `Body` witness is already declared, so only the `body` stub is added.
        self.synth_body_has_alias: set[str] = set()
        self.no_stored_props: set[str] = set()
        self.builder_names: set[str] = set()
        self._paths_with_init: set[str] = set()
        self.synthetic_extensions: dict[str, list[str]] = {}
        self.override_inits: set[str] = set()
        self.incompatible_records: list[dict[str, str]] = []

        for generator in generators:
            for container in walk_containers(generator.root):
                if container.kind == "module":
                    continue
                if container.is_property_wrapper:
                    self.attribute_names.add(container.path.split(".")[-1])
                if container.is_result_builder:
                    self.builder_names.add(container.path.split(".")[-1])
                if container.kind in ("struct", "class", "enum", "actor"):
                    self.type_kinds[container.path] = container.kind
                self.implemented.setdefault(container.path, set()).update(
                    member.name for member in container.members if member.kind != "import"
                )
                if container.kind == "protocol":
                    self.protocols[container.path] = (container, generator.module, generator.body)
                    simple = container.path.split(".")[-1]
                    self.protocol_by_name.setdefault(simple, []).append(container.path)

        # Result builders are also spelled through typealiases (`public typealias ContentBuilder =
        # ViewBuilder` in the interfaces themselves); a requirement or declaration carrying such an
        # attribute must be recognised as a builder too, so resolve aliases to a fixpoint.
        alias_targets: dict[str, str] = {}
        for generator in self.generators:
            for container in walk_containers(generator.root):
                for member in container.members:
                    if member.kind != "typealias" or member.name in alias_targets:
                        continue
                    text = generator.body[member.start:member.end]
                    equals = text.find("=")
                    if equals < 0:
                        continue
                    target = re.sub(r"<.*$", "", text[equals + 1:].strip(), flags=re.S).strip()
                    target = target.replace("::", ".")
                    alias_targets[member.name] = target.split(".")[-1].strip()
        changed = True
        while changed:
            changed = False
            for name, target in alias_targets.items():
                if name not in self.builder_names and target in self.builder_names:
                    self.builder_names.add(name)
                    changed = True

        for path, (container, _, body) in self.protocols.items():
            inherited: list[str] = []
            for conformance in container.conformances:
                resolved = self.resolve(conformance)
                if resolved and resolved != path:
                    inherited.append(resolved)
            self.inheritance[path] = inherited
            defaults: dict[str, str] = {}
            for member in container.members:
                if member.kind == "typealias" and member.keyword_span is not None:
                    text = body[member.start:member.end]
                    equals = text.find("=")
                    if equals >= 0 and member.name:
                        defaults[member.name] = text[equals + 1:].strip()
                elif member.kind == "associatedtype":
                    match = re.match(
                        r"associatedtype\s+(\w+)(?:\s*:[^=]*)?(?:=\s*(.+))?$",
                        body[member.start:member.end].strip(),
                        re.S,
                    )
                    if match and match.group(1) and match.group(2):
                        defaults[match.group(1)] = match.group(2).strip()
            self.associated_defaults[path] = defaults

        for generator in generators:
            for container in walk_containers(generator.root):
                if (
                    container.kind == "extension"
                    and container.path in self.protocols
                    and not container.has_where
                ):
                    self.defaults.setdefault(container.path, set()).update(
                        member.name for member in container.members if member.kind != "import"
                    )

        self.shim_type_kinds = load_shim_type_kinds()

    def type_kind(self, path: str) -> str | None:
        """Kind (struct/class/enum/actor) of a type: local declaration first, then shims."""
        kind = self.type_kinds.get(path)
        if kind:
            return kind
        return self.shim_type_kinds.get(path.split(".")[-1])

    # -- R10: duplicate associated-type witnesses (Apple's two module interfaces) ---------
    def association_names(self, protocol_path: str) -> set[str]:
        cached = self._assoc_names.get(protocol_path)
        if cached is not None:
            return cached
        names: set[str] = set()
        container, _, body = self.protocols[protocol_path]
        for member in container.members:
            if member.kind == "associatedtype":
                match = re.match(r"associatedtype\s+(\w+)", body[member.start:member.end].strip())
                if match:
                    names.add(match.group(1))
            elif member.kind == "typealias":
                names.add(member.name)
        for ancestor in self.ancestors(protocol_path):
            names |= self.association_names(ancestor)
        self._assoc_names[protocol_path] = names
        return names

    def _normalize_type_text(self, text: str) -> str:
        text = re.sub(r"\b(?:SwiftUI|SwiftUICore|Swift)(?:::|\.)", "", text)
        return re.sub(r"\s+", "", text)

    def declared_body_witness(self, path: str) -> str | None:
        """The type of a type's single (kept) `typealias Body`, if it declares one."""
        values: set[str] = set()
        for generator in self.generators:
            for container in walk_containers(generator.root):
                if container.path != path:
                    continue
                for member in container.members:
                    if member.kind != "typealias" or member.name != "Body":
                        continue
                    if id(member) in self.omitted:
                        continue
                    text = generator.body[member.start:member.end]
                    equals = text.find("=")
                    if equals >= 0:
                        values.add(text[equals + 1:].strip())
        if len(values) == 1:
            return values.pop()
        return None

    def _chosen_body_type(self, path: str) -> str | None:
        chosen = self.chosen_assoc.get((path, "Body"))
        return self._normalize_type_text(chosen) if chosen else None

    def reconcile_associated_types(self) -> None:
        """Collapse duplicate associated-type witnesses caused by merging the two interfaces.

        Apple ships `SwiftUI` and `SwiftUICore` as two modules, and a type may declare a
        different witness for the same associated type in each (for example `ForEach` has
        ``typealias Body = Never`` for `View` in SwiftUICore and
        ``typealias Body = ForEach<...>`` for `TabContent` in SwiftUI). In one module Swift
        allows only one witness per associated type, so the port keeps one and omits the others
        (the associated type itself is not lost: it keeps a single value). The kept value is the
        one that mentions the type itself when such a candidate exists (it is Apple's
        "natural" recursive body), otherwise the first non-`Never` one.

        The `body` properties are reconciled with it: the member whose declared type is the
        kept witness is retained, conflicting ones are omitted, and if none matches the
        requirement, R7 synthesizes one.
        """
        primary: dict[str, tuple["Generator", Container]] = {}
        for generator in self.generators:
            for container in walk_containers(generator.root):
                if container.kind in ("struct", "class", "enum", "actor"):
                    primary.setdefault(container.path, (generator, container))
        by_path: dict[str, list[tuple["Generator", Container]]] = {}
        for generator in self.generators:
            for container in walk_containers(generator.root):
                if container.kind == "module":
                    continue
                by_path.setdefault(container.path, []).append((generator, container))

        for path, entries in sorted(by_path.items()):
            if len(entries) < 2:
                # A single container can still declare a `body` whose type disagrees with the
                # type's `Body` witness (Apple's public closure property named `body`); reconcile
                # that below without touching associated types.
                self.reconcile_body_witness(path, entries)
                continue
            assoc_names: set[str] = set()
            for _, container in entries:
                for conformance in container.conformances:
                    protocol_path = self.resolve(conformance)
                    if protocol_path:
                        assoc_names |= self.association_names(protocol_path)
            for name in sorted(assoc_names):
                declarations = [
                    (generator, container, member)
                    for generator, container in entries
                    for member in container.members
                    if member.kind == "typealias" and member.name == name
                ]
                if len(declarations) < 2:
                    continue
                rhs: dict[int, str] = {}
                unconditional: dict[int, bool] = {}
                for generator, container, member in declarations:
                    text = generator.body[member.start:member.end]
                    equals = text.find("=")
                    if equals >= 0:
                        rhs[id(member)] = text[equals + 1:].strip()
                    unconditional[id(member)] = not container.has_where
                if len({self._normalize_type_text(v) for v in rhs.values()}) < 2:
                    continue
                if name == "Body":
                    # `Body` is constrained by protocols the type conforms to (`View`,
                    # `TabContent`, ...). A witness declared in a conditional extension is
                    # invisible to a conformance declared under different constraints, so no
                    # *conditional* spelling can serve every conformance. The port therefore
                    # declares `Body = Self` once, unconditionally, in the type itself: `Self`
                    # satisfies every `Body: P` constraint the type's own conformance declares,
                    # and `Self.TabValue == Self.Body.TabValue` holds by construction.
                    primary_entry = primary.get(path)
                    # `Self` is legal in an extension of a foreign type too (`Optional<Wrapped>`),
                    # where the witness is emitted as one unconditional extension.
                    chosen = "Self"
                    if primary_entry is not None and primary_entry[1].kind == "class":
                        chosen = "Never"
                else:
                    chosen = self._choose_witness_type(
                        path,
                        [(rhs[id(member)], unconditional[id(member)]) for _, _, member in declarations
                         if id(member) in rhs],
                    )
                self.chosen_assoc[(path, name)] = chosen
                for generator, container, member in declarations:
                    value = rhs.get(id(member))
                    if value is None:
                        continue
                    if name != "Body" and self._normalize_type_text(value) == self._normalize_type_text(chosen):
                        continue
                    self.omit(
                        generator, container, member,
                        f"duplicate associated-type witness '{name} = {value}' from Apple's other "
                        f"module interface; the port keeps '{chosen}' (R10)",
                    )
            body_members = [
                (generator, container, member)
                for generator, container in entries
                for member in container.members
                if member.kind in ("var", "let") and member.name == "body"
            ]
            if not body_members:
                continue
            typed: list[tuple[Generator, Container, Member, str]] = []
            for generator, container, member in body_members:
                span = member.result_type_span
                typed.append(
                    (generator, container, member,
                     generator.body[span[0]:span[1]] if span else "")
                )
            target = self._chosen_body_type(path)
            types = {self._normalize_type_text(text) for _, _, _, text in typed}
            if len(types) < 2:
                continue
            if (path, "Body") in self.chosen_assoc:
                # See above: drop every conditional `body` and declare one unconditional stub.
                for generator, container, member, text in typed:
                    self.omit(
                        generator, container, member,
                        f"conflicting 'body' witness ('{text}'); the port declares one "
                        f"unconditional `body: Never` (R10)",
                    )
                self.synth_body[path] = (
                    "Self" if self.chosen_assoc.get((path, "Body")) == "Self" else "Swift.Never"
                )
                continue
            if target is not None and target in types:
                keep = {id(member) for _, _, member, text in typed
                        if self._normalize_type_text(text) == target}
            elif target is not None:
                keep = set()
            elif len(types) == 1 and path not in self.synth_body:
                declared = self.declared_body_witness(path)
                if declared is not None and self._normalize_type_text(declared) not in types:
                    # The only declared `body` has a different type than the type's single
                    # `Body` witness (Apple's per-module shadowing again): drop it and declare
                    # the matching witness instead (R10).
                    for generator, container, member, text in typed:
                        self.omit(
                            generator, container, member,
                            f"'body' witness of type '{text}' conflicts with the declared "
                            f"'Body = {declared}'; the port declares the matching witness (R10)",
                        )
                    self.synth_body[path] = declared
                    self.implemented.setdefault(path, set()).discard("body")
                    continue
            else:
                counts: dict[str, int] = {}
                for _, _, _, text in typed:
                    normalized = self._normalize_type_text(text)
                    counts[normalized] = counts.get(normalized, 0) + 1
                best = sorted(counts.items(), key=lambda item: (-item[1], item[0]))[0][0]
                keep = {id(member) for _, _, member, text in typed
                        if self._normalize_type_text(text) == best}
            for generator, container, member, text in typed:
                if id(member) in keep:
                    continue
                self.omit(
                    generator, container, member,
                    f"conflicting 'body' witness ('{text}'); only one associated-type witness per "
                    f"type is legal in a single module, the port keeps "
                    f"'{self.chosen_assoc.get((path, 'Body'), 'the synthesized one')}' (R10)",
                )

    def reconcile_body_witness(
        self, path: str, entries: list[tuple["Generator", Container]]
    ) -> None:
        body_members = [
            (generator, container, member)
            for generator, container in entries
            for member in container.members
            if member.kind in ("var", "let") and member.name == "body"
            and member.accessors  # never drop a stored property: Apple's inlinable inits assign it
        ]
        if not body_members:
            return
        declared = self.declared_body_witness(path)
        if declared is None:
            return
        target = self._normalize_type_text(declared)
        typed = []
        for generator, container, member in body_members:
            span = member.result_type_span
            typed.append((generator, container, member, generator.body[span[0]:span[1]] if span else ""))
        if all(self._normalize_type_text(text) == target or not text for _, _, _, text in typed):
            return
        for generator, container, member, text in typed:
            if self._normalize_type_text(text) == target:
                continue
            self.omit(
                generator, container, member,
                f"'body' witness of type '{text}' conflicts with the declared 'Body = {declared}'; "
                f"the port declares the matching witness (R10)",
            )
        if path not in self.synth_body:
            self.synth_body[path] = declared
            self.synth_body_has_alias.add(path)
        self.implemented.setdefault(path, set()).discard("body")

    def _choose_witness_type(self, path: str, candidates: list[tuple[str, bool]]) -> str:
        """Pick the one associated-type witness the merged module keeps.

        An *unconditional* declaration wins: a witness declared in a `where`-constrained
        extension cannot satisfy an unconditional conformance (`extension ForEach : View` has no
        `where Content : TabContent`, so it cannot see `ForEach`'s `Body` if that was only
        declared for the `TabContent` conformance). Among equally unconditional candidates the
        one that mentions the type itself wins, then the most frequent one.
        """
        unconditional = [value for value, is_unconditional in candidates if is_unconditional]
        pools = [unconditional] if unconditional else []
        pools.append([value for value, _ in candidates])
        for scope in pools:
            normalized = [value for value in scope if self._normalize_type_text(value) != "Never"]
            type_name = path.split(".")[-1]
            self_named = [
                value for value in normalized
                if re.search(r"\b%s\b" % re.escape(type_name), self._normalize_type_text(value))
            ]
            pool = self_named or normalized
            if pool:
                counts: dict[str, int] = {}
                for value in pool:
                    counts[value] = counts.get(value, 0) + 1
                return sorted(counts.items(), key=lambda item: (-item[1], item[0]))[0][0]
            if any(self._normalize_type_text(value) == "Never" for value in scope):
                return "Never"
        return "Never"

    def omit(self, generator: "Generator", container: Container, member: Member, reason: str) -> None:
        key = (generator.spec.file_stem, member.start)
        if key in self.omitted_keys:
            return
        self.omitted_keys.add(key)
        self.omitted.add(id(member))
        self.omissions.append((generator, member, reason))

    def rebuild_implemented(self) -> None:
        self.implemented = {}
        for generator in self.generators:
            for container in walk_containers(generator.root):
                if container.kind == "module":
                    continue
                for member in container.members:
                    if member.kind == "import" or id(member) in self.omitted:
                        continue
                    self.implemented.setdefault(container.path, set()).add(member.name)

    def stored_property_paths(self) -> set[str]:
        paths: set[str] = set()
        for generator in self.generators:
            for container in walk_containers(generator.root):
                for member in container.members:
                    if member.kind in ("var", "let") and not member.accessors:
                        paths.add(container.path)
        return paths

    def _paths_with_init_declared(self) -> set[str]:
        paths: set[str] = set()
        for generator in self.generators:
            for container in walk_containers(generator.root):
                for member in container.members:
                    if member.kind == "init":
                        paths.add(container.path)
        return paths

    def class_superclass(self, container: Container) -> str | None:
        for conformance in container.conformances:
            kind = self.type_kinds.get(conformance) or self.shim_type_kinds.get(
                conformance.split(".")[-1]
            )
            if kind == "class":
                return conformance.split(".")[-1]
        return None

    def class_has_superclass(self, container: Container) -> bool:
        """True when the class inherits from another class (so `init()` needs `override`)."""
        return self.class_superclass(container) is not None

    def superclass_declares_parameterless_init(self, superclass: str) -> bool:
        if superclass in self.type_kinds:
            return superclass in self._paths_with_init
        # Shimmed class: look for an `init()` in its source declaration.
        for path in sorted(glob.glob(os.path.join(ROOT, "port-shims", "*", "*.swift"))):
            try:
                text = open(path, encoding="utf-8").read()
            except OSError:
                continue
            for match in re.finditer(r"\bclass\s+%s\b" % re.escape(superclass), text):
                window = text[match.end():match.end() + 3000]
                if re.search(r"\binit\s*\(\s*\)", window):
                    return True
        return False

    def init_paths(self) -> set[str]:
        paths: set[str] = set()
        for generator in self.generators:
            for container in walk_containers(generator.root):
                for member in container.members:
                    if member.kind == "init" and member.name == "init()":
                        paths.add(container.path)
        return paths

    # -- bootstrapping ----------------------------------------------------
    def prepare(self) -> None:
        """Run R10 reconciliation and compute the per-type facts later passes need."""
        self.reconcile_associated_types()
        self.rebuild_implemented()
        stored = self.stored_property_paths()
        inits = self.init_paths()
        primary: dict[str, tuple["Generator", Container]] = {}
        for generator in self.generators:
            for container in walk_containers(generator.root):
                if container.kind in ("struct", "class", "enum", "actor"):
                    primary.setdefault(container.path, (generator, container))
        self.synth_inits = {}
        self.no_stored_props = {path for path in primary if path not in stored}
        self._paths_with_init = self._paths_with_init_declared()
        for path, (generator, container) in primary.items():
            has_stored = path in stored
            has_init = path in inits
            if container.kind == "class":
                needed = has_stored and not has_init
            else:
                # A value type with no stored properties gets an implicit *internal* `init()`;
                # Apple's public interfaces use `T()` in default arguments, which needs a public
                # initializer.
                needed = not has_stored and not has_init
            if needed:
                self.synth_inits[path] = (generator, container)
                if container.kind == "class":
                    superclass = self.class_superclass(container)
                    if superclass and self.superclass_declares_parameterless_init(superclass):
                        self.override_inits.add(path)
        for path in sorted(self.synth_body):
            entry = primary.get(path)
            if entry is None:
                # A type declared by Apple as an extension of a foreign type (e.g. `Optional`,
                # `ForEach` lives elsewhere): append one unconditional extension instead.
                owner = next(
                    (gen for gen in self.generators
                     if any(c.path == path for c in walk_containers(gen.root))),
                    self.generators[0],
                )
                symbol_body = f"{owner.module}.{path}.body"
                target_type = self.synth_body[path]
                alias = "Self" if target_type == "Self" else target_type
                self.synthetic_extensions.setdefault(owner.spec.file_stem, []).append(
                    f"\n// port: unconditional `body` witness for the declared associated type (R10)\n"
                    f"extension {path} {{\n"
                    + (
                        ""
                        if path in self.synth_body_has_alias
                        else f"  public typealias Body = {alias}\n"
                    )
                    + f"  public var body: {target_type} {{ get {{ "
                    f"_suiUnimplemented(\"{symbol_body}\") }} }}\n"
                    f"}}\n"
                )
                owner.stats.bodies_injected += 1
                owner.record_body(symbol_body, "var", False)
                self.implemented.setdefault(path, set()).update({"Body", "body"})
                continue
            generator, container = entry
            symbol_typealias = f"{generator.module}.{path}.Body"
            symbol_body = f"{generator.module}.{path}.body"
            target_type = self.synth_body[path]
            target_alias = "Self" if target_type == "Self" else target_type
            indent = generator.indent_at(container.end - 1) if container.end else ""
            generator.edits.append(
                Edit(
                    container.end - 1, container.end - 1,
                    f"{indent}  // port: unconditional `body` witness for the declared "
                    f"associated type (R10)\n"
                    + (
                        ""
                        if container.path in self.synth_body_has_alias
                        else f"{indent}  public typealias Body = {target_alias}\n"
                    )
                    + f"{indent}  public var body: {target_type} {{ get {{ "
                    f"_suiUnimplemented(\"{symbol_body}\") }} }}\n",
                )
            )
            generator.stats.bodies_injected += 1
            generator.record_body(symbol_body, "var", False)
            self.implemented.setdefault(path, set()).update({"Body", "body"})
        # R12 is disabled: the unified `Body = Self` witness removed the need for `Never`
        # conformances, and the ones this pass emitted could not satisfy constrained associated
        # types (`Never.Scope` is not an `AttributeScope`), so it only added diagnostics.

    def incompatible_matches(self, container: Container) -> list[dict[str, str]]:
        """Conformance clauses of `container` that a single module cannot express."""
        simple = {conformance.split(".")[-1] for conformance in container.conformances}
        return [
            entry for entry in INCOMPATIBLE_CONFORMANCES
            if entry["type"] == container.path and entry["protocol"] in simple
        ]

    def resolve(self, path: str) -> str | None:
        candidates = self.protocol_by_name.get(path.split(".")[-1])
        if not candidates:
            return None
        return sorted(candidates)[0]

    def ancestors(self, protocol_path: str) -> list[str]:
        seen: set[str] = set()
        stack = list(self.inheritance.get(protocol_path, []))
        result: list[str] = []
        while stack:
            path = stack.pop()
            if path in seen:
                continue
            seen.add(path)
            result.append(path)
            stack.extend(self.inheritance.get(path, []))
        return result

    def substitutions_for(self, protocol_path: str, local: dict[str, str]) -> dict[str, str]:
        merged = dict(self.associated_defaults.get(protocol_path, {}))
        for ancestor in self.ancestors(protocol_path):
            for name, value in self.associated_defaults.get(ancestor, {}).items():
                merged.setdefault(name, value)
        merged.update(local)  # the type's own typealiases win
        return merged

    def has_default(self, protocol_path: str, name: str) -> bool:
        if name in self.defaults.get(protocol_path, set()):
            return True
        return any(
            name in self.defaults.get(ancestor, set()) for ancestor in self.ancestors(protocol_path)
        )

    def requirements(self, protocol_path: str) -> list[Requirement]:
        cached = self._requirements.get(protocol_path)
        if cached is not None:
            return cached
        result: list[Requirement] = []
        seen: set[tuple[str, str]] = set()
        for path in [protocol_path] + self.ancestors(protocol_path):
            container, _, body = self.protocols[path]
            for member in container.members:
                if member.kind not in ("func", "var", "let", "init", "subscript"):
                    continue
                if member.keyword_span is None:
                    continue
                key = (member.kind, member.name)
                if key in seen:
                    continue
                seen.add(key)
                result.append(
                    Requirement(
                        kind=member.kind,
                        name=member.name,
                        text=body[member.start:member.end],
                        accessors=member.accessors,
                        keyword_offset=member.keyword_span[0] - member.start,
                        block_offset=(
                            member.block_start - member.start
                            if member.block_start is not None
                            else None
                        ),
                        modifiers=[value for kind, value in member.prefix if kind == "mod"],
                    )
                )
        self._requirements[protocol_path] = result
        return result


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def load_implemented() -> set[str]:
    """Read `port-impl/implemented.txt`: one qualified symbol per line, `#` comments."""
    if not os.path.exists(IMPLEMENTED_PATH):
        return set()
    symbols: set[str] = set()
    with open(IMPLEMENTED_PATH, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if any(character.isspace() for character in line):
                raise GenerationError(
                    f"{os.path.relpath(IMPLEMENTED_PATH, ROOT)}:{number}: expected one symbol "
                    f"per line, got {line!r}"
                )
            symbols.add(line)
    return symbols


def generate() -> tuple[dict[str, str], list[Generator], "SharedModel"]:
    """Return ``({file_stem: source}, generators, shared)``."""
    implemented = load_implemented()
    generators = [Generator(spec, implemented) for spec in MODULE_SPECS]
    for generator in generators:
        generator.parse()
    shared = SharedModel(generators)
    shared.prepare()
    for generator in generators:
        generator.generate_edits(shared)
    sources = {
        generator.spec.file_stem: generator.render_source(shared.attribute_names)
        for generator in generators
    }

    # Apple's two interfaces are compiled as one module: a type declared in both would collide.
    owners: dict[str, tuple[str, str]] = {}
    collisions: list[str] = []
    for generator in generators:
        for path, kind in generator.toplevel_types.items():
            if path in owners and owners[path][0] != generator.spec.file_stem:
                collisions.append(
                    f"{kind} {path}: declared in {owners[path][0]} and {generator.spec.file_stem}"
                )
            else:
                owners[path] = (generator.spec.file_stem, kind)
    if collisions:
        raise GenerationError(
            "the two interfaces declare the same type; the port's single-module layout cannot "
            "represent that without a rename (report, do not rename):\n  " + "\n  ".join(collisions)
        )
    return sources, generators, shared


def build_manifest(generators: list[Generator], shared: "SharedModel") -> dict:
    manifests = [generator.manifest() for generator in generators]
    modules = {manifest["module"]: manifest["stats"] for manifest in manifests}
    totals = {key: sum(manifest["stats"][key] for manifest in manifests) for key in modules[manifests[0]["module"]]}
    bodies = [entry for manifest in manifests for entry in manifest["bodies"]]
    bodies.sort(key=lambda entry: (entry["module"], entry["symbol"], entry["kind"], entry["inlined"]))

    seam_symbols: dict[str, list[str]] = {}
    for manifest in manifests:
        for seam in manifest["seams"]:
            seam_symbols.setdefault(seam["category"], set()).add(seam["symbol"])
    seams = {
        category: {"count": len(sorted(symbols)), "symbols": sorted(symbols)}
        for category, symbols in sorted(seam_symbols.items())
    }
    overridden = sorted({symbol for manifest in manifests for symbol in manifest["overridden"]})
    projections = sorted({
        symbol for manifest in manifests for symbol in manifest["synthesized_projections_omitted"]
    })
    return {
        "schema": 1,
        "target": TARGET,
        "compiled_module": COMPILED_MODULE,
        "layout": "single-module: Generated/SwiftUICore.swift + Generated/SwiftUI.swift compile into module SwiftUI",
        "files": {manifest["file"]: manifest["module"] for manifest in manifests},
        "modules": modules,
        "stats": totals,
        "seams": {**seams, "total": sum(entry["count"] for entry in seams.values())},
        "overridden": {"count": len(overridden), "symbols": overridden},
        "synthesized_projections_omitted": {"count": len(projections), "symbols": projections},
        "synthesized_witnesses": {
            "count": totals["synthesized_witnesses"],
        },
        "unsupported_requirements": {
            "count": len(shared.unsupported),
            "symbols": sorted(shared.unsupported),
        },
        "bodies": bodies,
    }


def write_outputs(sources: dict[str, str], manifest: dict) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(MANIFEST_PATH), exist_ok=True)
    for file_stem, source in sources.items():
        with open(os.path.join(OUT_DIR, f"{file_stem}.swift"), "w", encoding="utf-8") as handle:
            handle.write(source)
    with open(MANIFEST_PATH, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, indent=2) + "\n")


def check_outputs(sources: dict[str, str], manifest: dict) -> list[str]:
    problems: list[str] = []
    for file_stem, source in sources.items():
        path = os.path.join(OUT_DIR, f"{file_stem}.swift")
        if not os.path.exists(path):
            problems.append(f"missing {os.path.relpath(path, ROOT)}")
            continue
        with open(path, encoding="utf-8") as handle:
            if handle.read() != source:
                problems.append(f"stale {os.path.relpath(path, ROOT)}")
    if not os.path.exists(MANIFEST_PATH):
        problems.append(f"missing {os.path.relpath(MANIFEST_PATH, ROOT)}")
    else:
        with open(MANIFEST_PATH, encoding="utf-8") as handle:
            if json.load(handle) != manifest:
                problems.append(f"stale {os.path.relpath(MANIFEST_PATH, ROOT)}")
    return problems


def main(argv: list[str]) -> int:
    argument_parser = argparse.ArgumentParser(
        description="Generate compilable SwiftUI source from Apple's retargeted module interfaces."
    )
    argument_parser.add_argument(
        "--check", action="store_true",
        help="do not write anything; exit 1 if the generated files or manifest are stale",
    )
    argument_parser.add_argument("--quiet", action="store_true", help="only print errors")
    argument_parser.add_argument(
        "--gen-dir", default=None,
        help="directory holding the retargeted <Module>.swiftmodule interfaces "
             "(default: build/port-sdk/gen)",
    )
    arguments = argument_parser.parse_args(argv)
    if arguments.gen_dir:
        global GEN_DIR
        GEN_DIR = os.path.abspath(arguments.gen_dir)

    sources, generators, shared = generate()
    manifest = build_manifest(generators, shared)

    if arguments.check:
        problems = check_outputs(sources, manifest)
        if problems:
            for problem in problems:
                print(f"stale: {problem}", file=sys.stderr)
            print("run scripts/port/inject_bodies.py to regenerate", file=sys.stderr)
            return 1
        if not arguments.quiet:
            print("generated sources are up to date")
        return 0

    write_outputs(sources, manifest)
    if not arguments.quiet:
        stats = manifest["stats"]
        print(f"generated {', '.join('Sources/SwiftUI/Generated/' + name for name in sources)}")
        print(f"manifest: {os.path.relpath(MANIFEST_PATH, ROOT)}")
        print(
            f"  declarations: {stats['declarations']}  types: {stats['types']}  "
            f"bodies injected: {stats['bodies_injected']}  "
            f"@inlinable bodies preserved: {stats['inlinable_bodies_preserved']}  "
            f"(bodies preserved: {stats['bodies_preserved']})"
        )
        print(
            f"  rewrites: opaque->Never {stats['opaque_rewrites']}  "
            f"static storage {stats['static_storage_rewrites']}  "
            f"module qualifiers removed {stats['self_qualifiers_removed']}  "
            f"projections omitted {stats['synthesized_projections_omitted']}  "
            f"overridden {stats['overridden']}  "
            f"synthesized witnesses {stats['synthesized_witnesses']}  "
            f"wrapper attrs removed {stats['wrapper_attributes_removed']}  "
            f"convenience inits {stats['convenience_init_rewrites']}"
        )
        if shared.unsupported:
            print(
                f"  WARNING: {len(shared.unsupported)} protocol requirements could not be "
                "synthesized (see manifest unsupported_requirements):",
                file=sys.stderr,
            )
            for symbol in shared.unsupported[:10]:
                print(f"    - {symbol}", file=sys.stderr)
        seams = manifest["seams"]
        print(
            "  seams: "
            + "  ".join(
                f"{category} {entry['count']}"
                for category, entry in seams.items()
                if category != "total"
            )
            + f"  (total {seams['total']})"
        )
        for module in MODULES:
            module_stats = manifest["modules"][module]
            print(
                f"  {module}: {module_stats['declarations']} declarations, "
                f"{module_stats['types']} types, "
                f"{module_stats['bodies_injected']} bodies injected, "
                f"{module_stats['inlinable_bodies_preserved']} inlinable bodies preserved"
            )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ParseError, GenerationError) as error:
        print(f"inject_bodies: {error}", file=sys.stderr)
        raise SystemExit(2)
