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

`_suiUnimplemented` is the seam to the port engine: see `Sources/SwiftUI/Engine/PortRuntime.swift`
for the SwiftUI-module implementation. `SwiftUICore.swift` (which may not import SwiftUI) carries
an equivalent definition of its own.

The result is deterministic: declarations are emitted in Apple's order, no timestamps, no
environment-dependent text. Re-running the script on the same interface reproduces the same bytes;
`--check` verifies that.

OUTPUT MANIFEST
---------------
`build/port-sdk/injected-bodies.json` lists every synthetic body the script added and every
`@inlinable` body it preserved, so engine work can be tracked as coverage:

    {
      "schema": 1,
      "target": "aarch64-unknown-linux-android28",
      "modules": { "SwiftUICore": {"declarations": 123, "bodies_injected": 456, ...} },
      "stats": {"declarations": ..., "bodies_injected": ..., "inlinable_bodies_preserved": ...},
      "bodies": [
        {"symbol": "SwiftUICore.LayoutDirection.hash(into:)", "module": "SwiftUICore",
         "kind": "func", "inlined": false},
        ...
        {"symbol": "SwiftUICore.View.disabled(_:)", "module": "SwiftUICore",
         "kind": "func", "inlined": true}
      ]
    }

`inlined: false` means "the port must implement this": the body is a placeholder that traps at
runtime and reports the symbol. `inlined: true` means Apple shipped an `@inlinable` body, which
is real Apple code (it may still reach stub bodies, but its own logic is Apple's).

DOCUMENTED REWRITE RULES
------------------------
Bodies are *additions*: they never change a declaration. Only the rules below change declaration
text, and every one of them is listed in the banner of the generated files and explained, with
the Apple construct it handles and the reason, in `docs/PORT-BODIES.md`:

  R1  self-module qualification removal (SwiftUICore.swift): `SwiftUICore::Foo` -> `Foo`.
      `::` is interface-only spelling; a module cannot import itself.
  R2  interface-only stored `static let` / `static var` -> read-only computed `static var`
      with an injected getter. A `.swiftinterface` describes static storage that lives in
      Apple's binary as `static let x: T` with no initializer; that spelling does not compile
      as source ("`static let` declaration requires an initializer expression or an explicitly
      stated getter"). The public API is unchanged: a read-only type property.
      (`let` becomes `var` because Swift has no computed `let`; both are read-only from the
      outside, so the API is identical.)
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

Project rule: no public declaration is ever deleted to make an error go away. If the script meets
a construct it cannot represent, it stops with a precise error rather than skipping it.

USAGE
-----
    scripts/port/inject_bodies.py              # regenerate Generated/*.swift + manifest
    scripts/port/inject_bodies.py --check      # verify files on disk are up to date (CI)
    scripts/port/generate.sh                   # regenerate + cross-compile check
    scripts/port/generate.sh --no-build        # regenerate only

See `docs/PORT-BODIES.md` for the rewrite-rule details, the manifest format and the exact
cross-compile command.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
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

MODULES = ("SwiftUICore", "SwiftUI")
#: Modules whose `.swiftinterface` is a dependency of the module below it. `SwiftUI` re-exports
#: `SwiftUICore`, so `Never` conformances declared by SwiftUICore are visible in SwiftUI.
DEPENDENCIES = {"SwiftUI": ("SwiftUICore",)}

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

#: `Never` conformances the standard library declares (`Never` conforms to these in Swift 6.4).
STDLIB_NEVER_CONFORMANCES = {
    "Equatable", "Hashable", "Comparable", "Sendable",
    "Encodable", "Decodable", "Codable", "Error",
    "CustomStringConvertible", "CustomDebugStringConvertible", "Escapable",
}

SEAM_FUNCTION = """\
/// The body-injection seam for this module.
///
/// Every declaration in this file that Apple ships without a body calls this function, which
/// reports the entry point and traps. The port implements real bodies in `Sources/SwiftUI/Engine/`
/// (see `PortRuntime.swift`); this definition exists because `SwiftUICore` cannot import
/// `SwiftUI`, so it cannot use SwiftUI's seam.
@inline(never)
public func _suiUnimplemented(_ symbol: String) -> Never {
    fatalError("SwiftUI port: unimplemented entry point \\(symbol). Add it to Sources/SwiftUI/Engine/.")
}
"""


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
    #: span of the `let`/`var` keyword (R2 rewrites `let` -> `var`)
    keyword_span: tuple[int, int] | None = None


@dataclass
class Container:
    kind: str  # module | struct | class | enum | protocol | extension | actor
    path: str  # type path without module qualifier, e.g. "Text.LineStyle"
    start: int
    end: int = 0
    members: list[Member] = field(default_factory=list)
    children: list["Container"] = field(default_factory=list)
    conformances: list[str] = field(default_factory=list)


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
    text = text.replace("::", ".")
    text = _strip_generics(text)
    parts = [part for part in text.strip().split(".") if part]
    if len(parts) > 1:
        parts = parts[1:]  # drop a leading module qualifier
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
            self.parse_type(container, keyword, start)
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

    def parse_type(self, container: Container, keyword: str, start: int) -> None:
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
            child = Container(kind="extension", path=path, start=start, conformances=conformances)
        else:
            name_token = self.tokens[self.i]
            if name_token.kind != "id":
                raise ParseError(self.text, name_token.start, f"expected a type name after {keyword}")
            name = name_token.text
            self.i += 1
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
            child = Container(kind=keyword, path=path, start=start)

        container.children.append(child)
        self.i += 1  # past '{'
        self.parse_container(child)
        child.end = self.tokens[self.i - 1].end

    def parse_conformances(self, header: str) -> list[str]:
        text = _WHERE_RE.split(header)[0]
        depth = 0
        for index, ch in enumerate(text):
            if ch in "<([":
                depth += 1
            elif ch in ">)]":
                depth -= 1
            elif ch == ":" and depth == 0:
                conformances = []
                for part in split_top_level_comma(text[index + 1:]):
                    name = normalize_type_path(part.replace(":", " "))
                    if name:
                        conformances.append(name.split(".")[-1])
                return conformances
        return []

    def parse_callable(
        self, container: Container, kind: str, prefix: list[tuple[str, str]], start: int
    ) -> Member:
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
        if not self.at_end() and self.tokens[self.i].text == "{":
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
        if not self.at_end() and self.tokens[self.i].text == "{":
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
        )

    def parse_typealias(self, prefix: list[tuple[str, str]], start: int) -> Member:
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
class ModuleStats:
    declarations: int = 0
    types: int = 0
    bodies_injected: int = 0
    inlinable_bodies_preserved: int = 0
    bodies_preserved: int = 0
    opaque_rewrites: int = 0
    static_storage_rewrites: int = 0
    self_qualifiers_removed: int = 0


class Generator:
    def __init__(self, module: str) -> None:
        self.module = module
        self.entries: list[BodyEntry] = []
        self.stats = ModuleStats()
        self.never_conformances: set[str] = set()
        self.opaque_typealias_paths: set[str] = set()
        self.edits: list[Edit] = []
        self.body = ""
        self.root: Container | None = None

    # -- input ------------------------------------------------------------
    def interface_path(self) -> str:
        return os.path.join(GEN_DIR, f"{self.module}.swiftmodule", f"{TARGET}.swiftinterface")

    def load(self) -> str:
        path = self.interface_path()
        if not os.path.exists(path):
            raise SystemExit(
                f"error: {path} not found. Run scripts/port/build-port-sdk.sh first."
            )
        with open(path, encoding="utf-8") as handle:
            interface = handle.read()
        # Drop the interface header (format/compiler/module-flags comments) and keep the body,
        # which starts at the first import line.
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
            for child in container.children:
                visit(child)

        visit(root)

    # -- edits ------------------------------------------------------------
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

    def record_body(self, symbol: str, kind: str, inlined: bool) -> None:
        self.entries.append(BodyEntry(symbol, self.module, kind, inlined))

    def generate_edits(self) -> None:
        assert self.root is not None

        def visit(container: Container, protocol_requirements: bool) -> None:
            for member in container.members:
                if member.kind == "import":
                    continue
                self.stats.declarations += 1
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
                    self.handle_callable(container, member)
                elif member.kind in ("var", "let"):
                    self.handle_property(container, member)
                elif member.kind == "deinit":
                    if not member.has_body:
                        self.edits.append(Edit(member.end, member.end, " {}"))
                        self.stats.bodies_injected += 1
                        self.record_body(self.symbol_for(container, member), "deinit", False)
                elif member.has_body:
                    self.stats.bodies_preserved += 1
                    if member.inlinable:
                        self.stats.inlinable_bodies_preserved += 1
                        self.record_body(self.symbol_for(container, member), member.kind, True)
            for child in container.children:
                self.stats.types += 1
                visit(child, child.kind == "protocol")

        visit(self.root, False)

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

    def handle_callable(self, container: Container, member: Member) -> None:
        symbol = self.symbol_for(container, member)
        if member.accessors:
            # A subscript with an accessor block (`{ get set }`), not a function body.
            if member.result_type_span is not None and "some" in self.span_text(member.result_type_span):
                if self.opaque_needs_never(member.result_type_span, container):
                    span = member.result_type_span
                    self.add_comment(
                        member.start,
                        "opaque result type is not expressible in source; declared as Never (R3)",
                    )
                    self.edits.append(Edit(span[0], span[1], "Swift.Never"))
                    self.stats.opaque_rewrites += 1
            self.inject_accessors(member, symbol, "subscript")
            return
        if member.has_body:
            self.stats.bodies_preserved += 1
            if member.inlinable:
                self.stats.inlinable_bodies_preserved += 1
                self.record_body(symbol, member.kind, True)
            return
        if member.result_type_span is not None and "some" in self.span_text(member.result_type_span):
            if self.opaque_needs_never(member.result_type_span, container):
                span = member.result_type_span
                self.add_comment(
                    member.start,
                    "opaque result type is not expressible in source; declared as Never (R3)",
                )
                self.edits.append(Edit(span[0], span[1], "Swift.Never"))
                self.stats.opaque_rewrites += 1
        self.edits.append(Edit(member.end, member.end, f' {{ _suiUnimplemented("{symbol}") }}'))
        self.stats.bodies_injected += 1
        self.record_body(symbol, member.kind, False)

    def span_text(self, span: tuple[int, int]) -> str:
        return self.body[span[0]:span[1]]

    def opaque_needs_never(self, span: tuple[int, int], container: Container) -> bool:
        base = base_protocol_name(self.span_text(span))
        if not base:
            return True
        if container.path in self.opaque_typealias_paths:
            return True
        if base in self.never_conformances or base in STDLIB_NEVER_CONFORMANCES:
            return False
        return True

    def handle_property(self, container: Container, member: Member) -> None:
        symbol = self.symbol_for(container, member)

        # Stored static storage cannot compile as source: give it a computed getter (R2).
        stored_static = (
            member.static and not member.accessors and member.result_type_span is not None
        )
        stored_in_extension = (
            container.kind == "extension" and not member.accessors and member.result_type_span is not None
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
                Edit(member.end, member.end, f' {{ get {{ _suiUnimplemented("{symbol}") }} }}')
            )
            self.stats.static_storage_rewrites += 1
            self.stats.bodies_injected += 1
            self.record_body(symbol, "var", False)
            return

        if member.result_type_span is not None and "some" in self.span_text(member.result_type_span):
            if self.opaque_needs_never(member.result_type_span, container):
                span = member.result_type_span
                self.add_comment(
                    member.start,
                    "opaque type is a witness for a declared associated type / has no Never "
                    "conformance; declared as Never (R3)",
                )
                self.edits.append(Edit(span[0], span[1], "Swift.Never"))
                self.stats.opaque_rewrites += 1

        if member.accessors:
            self.inject_accessors(member, symbol, "var")
            return

        # A stored instance property with no initializer is legal Swift (it is initialised by the
        # type's initialisers, whose bodies never return thanks to `_suiUnimplemented`).
        if member.has_body:
            self.stats.bodies_preserved += 1
            if member.inlinable:
                self.stats.inlinable_bodies_preserved += 1
                self.record_body(symbol, "var", True)

    # -- self-module qualification (R1) ------------------------------------
    def strip_self_qualification(self, text: str) -> str:
        if self.module != "SwiftUICore":
            return text
        tokens = tokenize(text)
        removals: list[Edit] = []
        index = 0
        while index < len(tokens):
            token = tokens[index]
            if (
                token.kind == "id"
                and token.text == self.module
                and index + 2 < len(tokens)
                and tokens[index + 1].text == ":"
                and tokens[index + 2].text == ":"
            ):
                removals.append(Edit(token.start, tokens[index + 2].end, ""))
                index += 3
                continue
            index += 1
        self.stats.self_qualifiers_removed = len(removals)
        return apply_edits(text, removals)

    # -- rendering ---------------------------------------------------------
    def banner(self) -> str:
        lines = [
            f"// {self.module}.swift — GENERATED FILE, DO NOT EDIT BY HAND.",
            "//",
            "// Source: Apple's own module interface",
            f"//   <iOS Simulator SDK>/{self.module}.framework/Modules/{self.module}.swiftmodule/"
            "arm64-apple-ios-simulator.swiftinterface",
            f"// retargeted to {TARGET} by scripts/port/build-port-sdk.sh, then turned into",
            "// compilable Swift by scripts/port/inject_bodies.py. Regenerate with",
            "// `scripts/port/generate.sh`; see docs/PORT-BODIES.md.",
            "//",
            "// Every declaration below is Apple's text byte-for-byte. The port adds",
            "//   * `{ _suiUnimplemented(\"<symbol>\") }` bodies for declarations Apple ships bodyless,",
            "//   * bodies for bodyless property accessors,",
            "//   * `{}` for bodyless `deinit`s,",
            "// and applies the documented rewrite rules (details in docs/PORT-BODIES.md):",
            "//",
            "//   R1  SwiftUICore::Foo -> Foo  (self-module qualification; a module cannot import itself)",
            "//   R2  stored static `let x: T` -> computed read-only `static var x: T { get { ... } }`",
            "//       (interface-only spelling of Apple's binary storage; no initializer in source)",
            "//   R3  `@_opaqueReturnTypeOf(...)` typealiases and opaque results that cannot be",
            "//       expressed in source -> `Swift.Never`",
            "//   R4  Apple-compiler `#if` feature conditions are evaluated for the pinned toolchain;",
            "//       dead fallback branches are preserved verbatim but not injected into",
            "//",
            "// `@inlinable` bodies are Apple's real code and are never modified.",
            "",
        ]
        return "\n".join(lines)

    def render(self) -> tuple[str, str]:
        """Return ``(source, manifest_json)``."""
        body = self.load()
        parse_text = preprocess_conditionals(body)
        parser = Parser(body, parse_text)
        root = parser.parse()
        self.root = root
        self.body = body
        self.collect_never_conformances(root)
        for dependency in DEPENDENCIES.get(self.module, ()):
            dependency_generator = Generator(dependency)
            dependency_body = dependency_generator.load()
            dependency_root = Parser(
                dependency_body, preprocess_conditionals(dependency_body)
            ).parse()
            dependency_generator.collect_never_conformances(dependency_root)
            self.never_conformances |= dependency_generator.never_conformances
        self.collect_opaque_typealiases(root)
        self.generate_edits()
        edited = apply_edits(body, self.edits)
        edited = self.strip_self_qualification(edited)

        parts = [self.banner()]
        if self.module == "SwiftUICore":
            # The seam must live in this module: SwiftUICore cannot import SwiftUI (circular).
            parts.append(SEAM_FUNCTION)
            parts.append("")
        parts.append(edited)
        source = "".join(parts)

        manifest = json.dumps(self.manifest(), indent=2, sort_keys=False) + "\n"
        return source, manifest

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
            "schema": 1,
            "target": TARGET,
            "modules": {
                self.module: {
                    "declarations": self.stats.declarations,
                    "types": self.stats.types,
                    "bodies_injected": self.stats.bodies_injected,
                    "bodies_preserved": self.stats.bodies_preserved,
                    "inlinable_bodies_preserved": self.stats.inlinable_bodies_preserved,
                    "opaque_rewrites": self.stats.opaque_rewrites,
                    "static_storage_rewrites": self.stats.static_storage_rewrites,
                    "self_qualifiers_removed": self.stats.self_qualifiers_removed,
                }
            },
            "stats": {
                "declarations": self.stats.declarations,
                "types": self.stats.types,
                "bodies_injected": self.stats.bodies_injected,
                "bodies_preserved": self.stats.bodies_preserved,
                "inlinable_bodies_preserved": self.stats.inlinable_bodies_preserved,
                "opaque_rewrites": self.stats.opaque_rewrites,
                "static_storage_rewrites": self.stats.static_storage_rewrites,
                "self_qualifiers_removed": self.stats.self_qualifiers_removed,
            },
            "bodies": bodies,
        }


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def generate() -> dict[str, tuple[str, str]]:
    """Generate both modules in memory: module -> (source, json)."""
    results: dict[str, tuple[str, str]] = {}
    for module in MODULES:
        results[module] = Generator(module).render()
    return results


def combined_stats(results: dict[str, tuple[str, str]]) -> dict:
    manifests = {module: json.loads(text) for module, (_, text) in results.items()}
    total = {
        "declarations": sum(m["stats"]["declarations"] for m in manifests.values()),
        "types": sum(m["stats"]["types"] for m in manifests.values()),
        "bodies_injected": sum(m["stats"]["bodies_injected"] for m in manifests.values()),
        "bodies_preserved": sum(m["stats"]["bodies_preserved"] for m in manifests.values()),
        "inlinable_bodies_preserved": sum(
            m["stats"]["inlinable_bodies_preserved"] for m in manifests.values()
        ),
        "opaque_rewrites": sum(m["stats"]["opaque_rewrites"] for m in manifests.values()),
        "static_storage_rewrites": sum(
            m["stats"]["static_storage_rewrites"] for m in manifests.values()
        ),
        "self_qualifiers_removed": sum(
            m["stats"]["self_qualifiers_removed"] for m in manifests.values()
        ),
    }
    total["manifest_entries"] = sum(len(m["bodies"]) for m in manifests.values())
    return {"stats": total, "modules": {k: v["stats"] for k, v in manifests.items()}}


def write_outputs(results: dict[str, tuple[str, str]]) -> dict:
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(MANIFEST_PATH), exist_ok=True)
    for module, (source, _) in results.items():
        path = os.path.join(OUT_DIR, f"{module}.swift")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(source)
    summary = combined_stats(results)
    manifests = {module: json.loads(text) for module, (_, text) in results.items()}
    for module in MODULES:
        summary["modules"][module] = manifests[module]["stats"]
    summary["schema"] = 1
    summary["target"] = TARGET
    summary["bodies"] = [entry for module in MODULES for entry in manifests[module]["bodies"]]
    summary["bodies"].sort(key=lambda e: (e["module"], e["symbol"], e["kind"], e["inlined"]))
    with open(MANIFEST_PATH, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(summary, indent=2) + "\n")
    return summary


def check_outputs(results: dict[str, tuple[str, str]]) -> list[str]:
    problems: list[str] = []
    for module, (source, _) in results.items():
        path = os.path.join(OUT_DIR, f"{module}.swift")
        if not os.path.exists(path):
            problems.append(f"missing {os.path.relpath(path, ROOT)}")
            continue
        with open(path, encoding="utf-8") as handle:
            if handle.read() != source:
                problems.append(f"stale {os.path.relpath(path, ROOT)}")
    manifests = {module: json.loads(text) for module, (_, text) in results.items()}
    expected = {
        "schema": 1,
        "target": TARGET,
        "modules": {module: manifests[module]["stats"] for module in MODULES},
        "stats": combined_stats(results)["stats"],
        "bodies": sorted(
            (entry for module in MODULES for entry in manifests[module]["bodies"]),
            key=lambda e: (e["module"], e["symbol"], e["kind"], e["inlined"]),
        ),
    }
    if not os.path.exists(MANIFEST_PATH):
        problems.append(f"missing {os.path.relpath(MANIFEST_PATH, ROOT)}")
    else:
        with open(MANIFEST_PATH, encoding="utf-8") as handle:
            if json.load(handle) != expected:
                problems.append(f"stale {os.path.relpath(MANIFEST_PATH, ROOT)}")
    return problems


def main(argv: list[str]) -> int:
    argument_parser = argparse.ArgumentParser(
        description="Generate compilable SwiftUI/SwiftUICore source from Apple's module interfaces."
    )
    argument_parser.add_argument(
        "--check", action="store_true",
        help="do not write anything; exit 1 if the generated files or manifest are stale",
    )
    argument_parser.add_argument(
        "--quiet", action="store_true", help="only print errors",
    )
    arguments = argument_parser.parse_args(argv)

    results = generate()
    if arguments.check:
        problems = check_outputs(results)
        if problems:
            for problem in problems:
                print(f"stale: {problem}", file=sys.stderr)
            print("run scripts/port/inject_bodies.py to regenerate", file=sys.stderr)
            return 1
        if not arguments.quiet:
            print("generated sources are up to date")
        return 0

    summary = write_outputs(results)
    if not arguments.quiet:
        stats = summary["stats"]
        print(
            "generated Sources/SwiftUI/Generated/{SwiftUICore,SwiftUI}.swift and "
            f"{os.path.relpath(MANIFEST_PATH, ROOT)}"
        )
        print(
            f"  declarations: {stats['declarations']}  types: {stats['types']}  "
            f"bodies injected: {stats['bodies_injected']}  "
            f"@inlinable bodies preserved: {stats['inlinable_bodies_preserved']}  "
            f"(bodies preserved: {stats['bodies_preserved']})"
        )
        print(
            f"  rewrites: opaque->Never {stats['opaque_rewrites']}  "
            f"static storage {stats['static_storage_rewrites']}  "
            f"self-qualifiers removed {stats['self_qualifiers_removed']}"
        )
        for module in MODULES:
            module_stats = summary["modules"][module]
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
    except ParseError as error:
        print(f"inject_bodies: unsupported interface construct: {error}", file=sys.stderr)
        raise SystemExit(2)
