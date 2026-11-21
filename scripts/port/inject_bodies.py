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
types are spelled with the compiler-internal `@_opaqueReturnTypeOf(...)` attribute, and
type names are module-qualified with `::` instead of Swift's usual `.`.

This script reads the retargeted interface and writes ordinary Swift source:

    Sources/SwiftUI/Generated/SwiftUICore.swift
    Sources/SwiftUI/Generated/SwiftUI.swift

for every declaration Apple wrote, exactly the text Apple wrote. The only changes are the
*additions* needed to make that text legal Swift outside Apple's SDK:

  * a bodyless `func` / `init` / `subscript` gets `{ _suiUnimplemented("<symbol>") }`
  * a bodyless computed property (`{ get }`, `{ get set }`, …) gets bodies on every
    bodyless accessor: `{ get { _suiUnimplemented("…") } set { _suiUnimplemented("…") } }`
  * a bodyless `deinit` gets `{}`
  * `@inlinable` bodies are Apple's own code and are kept byte-for-byte, never touched
  * protocol requirements keep no body (that is legal Swift)

`_suiUnimplemented` is the seam to the port engine: see `Sources/SwiftUI/Engine/PortRuntime.swift`
for the SwiftUI-module implementation. `SwiftUICore.swift` (which may not import SwiftUI) carries
an equivalent definition of its own.

The result is deterministic: declarations are emitted in Apple's order, no timestamps, no
environment-dependent text. Re-running the script on the same interface reproduces the same bytes.

OUTPUT MANIFEST
---------------
`build/port-sdk/injected-bodies.json` lists every synthetic body the script added and every
`@inlinable` body it preserved, so the engine work can be tracked as coverage:

    {
      "schema": 1,
      "target": "aarch64-unknown-linux-android28",
      "modules": { "SwiftUICore": {...}, "SwiftUI": {...} },
      "stats": {...},
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
is already real Swift code (it still calls into stub bodies, but its own logic is Apple's).

DOCUMENTED REWRITE RULES
------------------------
Rules 1-2 are the only places where a declaration's *text* changes (bodies are additions, not
changes). Every rule is listed in the banner of each generated file and explained, with the
Apple construct it handles and the reason, in `docs/PORT-BODIES.md`:

  R1  self-module qualification removal (SwiftUICore.swift): `SwiftUICore::Foo` -> `Foo`.
      `::` is interface-only spelling; a module cannot import itself.
  R2  interface-only stored `static let`/`static var` -> read-only computed `static var`
      with an injected getter. A `.swiftinterface` describes static storage that lives in
      Apple's binary as `static let x: T` with no initializer; that spelling does not compile
      as source ("`static let` declaration requires an initializer expression or an explicitly
      stated getter"). The public API is unchanged: a read-only type property.
  R3  opaque result types that cannot be expressed as source:
        - `@_opaqueReturnTypeOf("$s…", 0) __<…>` typealiases (resolved against Apple's binary
          symbols only) become `Swift.Never`;
        - a bodyless property whose opaque result is the declared associated type of its type
          (e.g. `var body: some View` with `typealias Body = @_opaqueReturnTypeOf(…)`) gets the
          concrete type `Swift.Never`, because a witness must have the associated type, not an
          anonymous opaque type.
      `Never` is the port's bottom type and Apple declares `extension Never : View` (and the
      other `some`-result protocols) itself, so the resulting declarations still typecheck.
  R4  `#if` conditionals whose condition is an Apple-compiler feature flag
      (`compiler(>=5.3) && $TildeSendable`, `$InlineAlways`, `$AsyncExecutionBehaviorAttributes`)
      are evaluated for the pinned toolchain (swift 6.4.3: all true). Bodies are injected only
      into the branch that is compiled; the dead fallback branch is preserved verbatim so the
      file still shows exactly what Apple declares.

Never rule 4 of the project rules: no public declaration is ever deleted to make an error go
away. If the script meets a construct it cannot represent, it stops with a precise error.

USAGE
-----
    scripts/port/inject_bodies.py              # regenerate Generated/*.swift + manifest
    scripts/port/inject_bodies.py --check      # verify files on disk are up to date (CI)
    scripts/port/generate.sh                   # regenerate + cross-compile check (see below)

`generate.sh` runs this script and then cross-compiles both generated modules with the Swift SDK
for Android; see its header and `docs/PORT-BODIES.md` for the exact command.
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

#: Modules whose `.swiftinterface` is compiled as a *dependency* by the module below it.
#: `SwiftUICore` is imported by `SwiftUI` (Apple re-exports it), so Never-conformances that
#: `SwiftUICore` declares are visible when resolving `some` result types in `SwiftUI`.
DEPENDENCIES = {"SwiftUI": ("SwiftUICore",)}

# ---------------------------------------------------------------------------
# Swift lexical knowledge
# ---------------------------------------------------------------------------

#: Declaration modifiers. The parser skips these (plus attributes) before the declaration
#: keyword. `class` is handled specially: it is a modifier in `class func`, a keyword otherwise.
MODIFIERS = {
    "public", "private", "internal", "fileprivate", "package", "open",
    "static", "final", "override", "required", "convenience",
    "nonisolated", "mutating", "nonmutating", "lazy", "weak", "unowned",
    "dynamic", "optional", "indirect", "distributed",
    "prefix", "postfix", "infix",
    "sending", "consuming", "borrowing",
}

#: Keywords that start a type declaration and therefore open a new brace scope.
TYPE_KEYWORDS = {"struct", "class", "enum", "protocol", "extension", "actor"}
#: Keywords that start a declaration (used to recognise a declaration boundary).
DECL_KEYWORDS = TYPE_KEYWORDS | {
    "func", "init", "deinit", "var", "let", "subscript",
    "typealias", "associatedtype", "case", "import", "macro",
    "operator", "precedencegroup",
}
#: Accessor keywords that can appear in a property/subscript accessor block.
ACCESSOR_KEYWORDS = {"get", "set", "_modify", "_read", "willSet", "didSet"}
#: Characters Swift allows in an operator name.
OPERATOR_CHARS = set("=+-*/%<>&|^~?!.")

#: `@inlinable` (and `@inline(__always)`, which is always paired with it) mark Apple's real bodies.
INLINABLE_ATTRS = {"inlinable"}


class ParseError(Exception):
    """Raised when the interface contains a construct this script does not understand."""

    def __init__(self, text: str, offset: int, message: str) -> None:
        line = text.count("\n", 0, offset) + 1
        column = offset - (text.rfind("\n", 0, offset) + 1) + 1
        super().__init__(f"line {line}:{column}: {message}")


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

    Handles raw strings (``#"…"#``), multi-line strings (``\"\"\"…\"\"\"``) and interpolation
    (``\\( … )``) including nested strings and parentheses inside the interpolation.
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
                # String interpolation: skip the balanced parenthesised expression, which may
                # itself contain strings and comments.
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
                    if ch == "(" or ch == "[" or ch == "{":
                        depth += 1
                    elif ch == ")" or ch == "]" or ch == "}":
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
    raise ParseError(text, i, "unterminated string literal")


def tokenize(text: str) -> list[Token]:
    """Tokenize Swift source just enough to track declarations, braces and string literals.

    Comments are dropped; everything else is emitted as ``id``, ``number``, ``string`` or
    single-character punctuation. The script never reconstructs source from tokens — it only
    needs offsets — so token text does not have to be exact beyond identifiers and punctuation.
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
            # Raw single-line/raw multi-line string literal.
            j = _scan_string(text, i)
            tokens.append(Token(text[i:j], i, j, "string"))
            i = j
            continue
        if ch == '"':
            j = _scan_string(text, i)
            tokens.append(Token(text[i:j], i, j, "string"))
            i = j
            continue
        if ch.isalpha() or ch == "_" or ch == "$":
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
# Conditional compilation (`#if` … `#else` … `#endif`)
# ---------------------------------------------------------------------------

#: Feature conditions the retargeted interfaces use. `swiftc -version` 6.4.3 defines all three
#: (`-enable-experimental-feature` defaults of the compiler that produced the interface); they
#: only select between two spellings of the *same* API (with/without `~Sendable`,
#: `@inline(always)` vs `@inline(__always)`), so for the pinned toolchain the `#if` branch is
#: the compiled one. This is verified by `generate.sh` (compiling proves which branch is live).
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
    # Split on top-level `&&` / `||` (no parentheses are used by Apple's interfaces).
    parts = re.split(r"\s*(&&|\|\|)\s*", expr)
    result = None
    operator = None
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
        value = True
        if result is None:
            result = value
        elif operator == "&&":
            result = result and value
        elif operator == "||":
            result = result or value
        else:
            raise ParseError(text, offset, f"malformed #if condition {expr!r}")
    return bool(result)


def preprocess_conditionals(body: str) -> tuple[str, int]:
    """Blank out `#if` directive lines and dead branches; keep byte offsets intact.

    Returns ``(parse_text, blanked_line_count)``. ``parse_text`` has the same length as ``body``
    (every character replaced by a space except newlines), so every offset the parser produces
    is directly usable as an edit offset into the *original* text.
    """
    lines: list[tuple[int, int]] = []  # (start, end) with the trailing newline included
    start = 0
    for line in body.splitlines(keepends=True):
        lines.append((start, start + len(line)))
        start += len(line)
    if start < len(body):  # no trailing newline
        lines.append((start, len(body)))

    out = list(body)
    stack: list[dict] = []
    active = True
    blanked = 0

    def blank(line_start: int, line_end: int) -> None:
        nonlocal blanked
        blanked += 1
        for k in range(line_start, line_end):
            if out[k] != "\n":
                out[k] = " "

    for line_start, line_end in lines:
        raw = body[line_start:line_end]
        stripped = raw.rstrip("\n")
        match = _DIRECTIVE_RE.match(stripped)
        if match:
            kind, rest = match.group(1), match.group(2)
            if kind == "if":
                cond = _eval_condition(rest, body, line_start)
                stack.append({"outer": active, "taken": cond and active, "any_taken": cond})
                active = active and cond
            elif kind == "elseif":
                if not stack:
                    raise ParseError(body, line_start, "#elseif without #if")
                frame = stack[-1]
                cond = _eval_condition(rest, body, line_start) if frame["outer"] else False
                taken = frame["outer"] and not frame["any_taken"] and cond
                frame["taken"] = taken
                frame["any_taken"] = frame["any_taken"] or cond
                active = taken
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
    return "".join(out), blanked


# ---------------------------------------------------------------------------
# Declaration model
# ---------------------------------------------------------------------------


@dataclass
class Accessor:
    keyword: str
    keyword_end: int  # offset just past the accessor keyword: where a body would start
    has_body: bool
    inlinable: bool


@dataclass
class Member:
    kind: str  # func | init | deinit | var | let | subscript | typealias | associatedtype | case | macro | operator | import
    name: str  # display name, e.g. "padding(_:)" / "body" / "init(_:)"
    start: int  # offset of the first attribute/modifier token
    end: int  # offset just past the last token of the declaration
    static: bool = False
    inlinable: bool = False
    has_body: bool = False
    accessors: list[Accessor] = field(default_factory=list)
    #: span of the *declared* result type / property type (offsets), used for opaque rewrites
    result_type_span: tuple[int, int] | None = None
    #: span of an `@_opaqueReturnTypeOf(...)` typealias right-hand side
    opaque_typealias_span: tuple[int, int] | None = None


@dataclass
class Container:
    kind: str  # module | struct | class | enum | protocol | extension | actor
    path: str  # type path without module qualifier, e.g. "Text.LineStyle"
    start: int
    members: list[Member] = field(default_factory=list)
    children: list["Container"] = field(default_factory=list)
    #: name of the extended type for `extension` containers (already normalised)
    extension_target: str | None = None


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

#: Declaration keywords that end at the current line (no braces, no injected bodies).
_LINE_KEYWORDS = {"import", "operator"}


class Parser:
    def __init__(self, text: str, parse_text: str, module: str) -> None:
        self.text = text  # original body text (for error context)
        self.parse_text = parse_text  # same length, conditionals blanked
        self.module = module
        self.tokens = tokenize(parse_text)
        self.i = 0
        # map offset -> line index for "first token of its line" detection
        self.line_starts: list[int] = [0]
        for m in re.finditer(r"\n", parse_text):
            self.line_starts.append(m.end())

    # -- token helpers ----------------------------------------------------
    def tok(self, offset: int = 0) -> Token | None:
        index = self.i + offset
        return self.tokens[index] if index < len(self.tokens) else None

    def text_of(self, token: Token) -> str:
        return token.text

    def at_end(self) -> bool:
        return self.i >= len(self.tokens)

    def is_first_on_line(self, token: Token) -> bool:
        line = bisect_right(self.line_starts, token.start) - 1
        return self.parse_text[self.line_starts[line]:token.start].strip() == ""

    def starts_declaration_line(self, token: Token) -> bool:
        if not self.is_first_on_line(token):
            return False
        if token.text in ("@", "}"):
            return True
        return token.kind == "id" and token.text in MODIFIERS | DECL_KEYWORDS

    def skip_balanced(self, index: int) -> int:
        """``index`` points at `(`, `[` or `{`; return the index just past its match."""
        openers = {"(": ")", "[": "]", "{": "}"}
        opener = self.tokens[index].text
        if opener not in openers:
            raise ParseError(self.text, self.tokens[index].start, f"expected a bracket, got {opener!r}")
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
        while index < len(self.tokens):
            token = self.tokens[index]
            if token.text == "-" and self.tokens[index + 1].text == ">":
                index += 2  # `->` is not a closing angle bracket
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
        """Consume one attribute: ``@Name``, ``@Module.Name``, optional `(arguments)`."""
        assert self.tokens[self.i].text == "@"
        self.i += 1
        if self.at_end():
            raise ParseError(self.text, self.tokens[-1].start, "attribute without a name")
        self.i += 1  # attribute name
        while not self.at_end() and self.tokens[self.i].text == ".":
            self.i += 2
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
            if token.text == "class":
                nxt = self.peek_text(1)
                if nxt in ("func", "var", "subscript"):
                    self.i += 1
                    prefix.append(("mod", "class"))
                    continue
            break
        return prefix

    def peek_text(self, offset: int = 0) -> str | None:
        token = self.tok(offset)
        return token.text if token else None

    def consume_current_line(self) -> None:
        if self.at_end():
            return
        line = self.tokens[self.i].start
        while not self.at_end():
            token = self.tokens[self.i]
            if token.start != line and self.is_first_on_line(token):
                break
            if self.is_first_on_line(token) and token.start != line:
                break
            self.i += 1
            if self.at_end() or self.is_first_on_line(self.tokens[self.i]):
                break

    # -- scanning helpers -------------------------------------------------
    def scan_type(self, index: int) -> int:
        """Consume a type expression; return the offset just past it.

        A type ends at a declaration boundary: `{`, a closing `}`, `where`, a first-on-line
        token that begins a new declaration, or end of input. Parens/brackets are balanced.
        """
        depth = 0
        last_end = self.tokens[index].start if index < len(self.tokens) else 0
        while index < len(self.tokens):
            token = self.tokens[index]
            if depth == 0:
                if token.text in ("{", "}"):
                    return last_end
                if token.text == "where":
                    return last_end
                if self.starts_declaration_line(token):
                    return last_end
            if token.text in ("(", "["):
                depth += 1
            elif token.text in (")", "]"):
                depth -= 1
                if depth < 0:
                    return last_end
            last_end = token.end
            index += 1
        return last_end

    def scan_expression(self, index: int) -> int:
        """Consume an initializer/where expression; same boundary rules as :meth:`scan_type`."""
        return self.scan_type(index)

    def skip_braces(self) -> None:
        """``self.i`` points at `{`; consume through the matching `}`."""
        self.i = self.skip_balanced(self.i)

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
            raise ParseError(self.text, len(self.text), f"unterminated {container.kind} {container.path}")

    # -- declarations ------------------------------------------------------
    def parse_declaration(self, container: Container) -> None:
        start = self.tokens[self.i].start if not self.at_end() else len(self.text)
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
        if keyword == "func":
            container.members.append(self.parse_callable(container, "func", prefix, start))
            return
        if keyword == "init":
            container.members.append(self.parse_callable(container, "init", prefix, start))
            return
        if keyword == "subscript":
            container.members.append(self.parse_callable(container, "subscript", prefix, start))
            return
        if keyword in ("var", "let"):
            container.members.append(self.parse_property(container, keyword, prefix, start))
            return
        if keyword == "deinit":
            container.members.append(self.parse_deinit(prefix, start))
            return
        if keyword == "typealias":
            container.members.append(self.parse_typealias(prefix, start))
            return
        if keyword in ("associatedtype", "case"):
            container.members.append(self.parse_plain(keyword, prefix, start))
            return
        if keyword == "macro":
            container.members.append(self.parse_plain("macro", prefix, start))
            return
        if keyword == "precedencegroup":
            self.i += 1
            while not self.at_end() and self.tokens[self.i].text != "{":
                self.i += 1
            if self.at_end():
                raise ParseError(self.text, start, "precedencegroup without a body")
            self.skip_braces()
            container.members.append(Member("precedencegroup", "precedencegroup", start, self.tokens[self.i - 1].end))
            return
        raise ParseError(
            self.text, token.start,
            f"unsupported declaration keyword {keyword!r} in {container.kind} {container.path or self.module}",
        )

    def parse_type(self, container: Container, keyword: str, prefix: list[tuple[str, str]], start: int) -> None:
        self.i += 1  # keyword
        if keyword == "extension":
            name_start = self.tokens[self.i].start
            while not self.at_end() and self.tokens[self.i].text != "{":
                token = self.tokens[self.i]
                if token.text in ("(", "[", "<"):
                    self.i = self.skip_balanced(self.i) if token.text in ("(", "[") else self.skip_angle(self.i)
                    continue
                if token.text == "}":
                    raise ParseError(self.text, token.start, "extension without a body")
                self.i += 1
            if self.at_end():
                raise ParseError(self.text, start, "extension without a body")
            name_end = self.tokens[self.i - 1].end
            name = normalize_type_path(self.text[name_start:name_end])
            kind = "extension"
        else:
            name_token = self.tokens[self.i]
            if name_token.kind != "id":
                raise ParseError(self.text, name_token.start, f"expected a type name after {keyword}")
            name = name_token.text
            self.i += 1
            while not self.at_end() and self.tokens[self.i].text != "{":
                token = self.tokens[self.i]
                if token.text in ("(", "[", "<"):
                    self.i = self.skip_balanced(self.i) if token.text in ("(", "[") else self.skip_angle(self.i)
                    continue
                self.i += 1
            if self.at_end():
                raise ParseError(self.text, start, f"{keyword} {name} without a body")
            kind = keyword

        # `self.i` points at the opening brace of the type body.
        if kind == "extension":
            path = name
            extension_target = name
            child_path = name
        else:
            child_path = f"{container.path}.{name}" if container.path else name
            path = child_path
            extension_target = None
        if self.at_end():
            raise ParseError(self.text, start, "type without a body")
        self.skip_braces()
        child = Container(
            kind=kind, path=path, start=start, extension_target=extension_target
        )
        # Re-parse the body: skip_braces already validated brace balance; walk members instead.
        # Rewind to just after the opening brace.
        raise NotImplementedError  # replaced below by inline parsing


# ---------------------------------------------------------------------------
# Type-path helpers
# ---------------------------------------------------------------------------

_WHERE_RE = re.compile(r"\s+where\s")


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
    # Remove generic arguments (`Foo<Bar, Baz>` -> `Foo`).
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
    parts = [part for part in text.strip().split(".") if part]
    # Drop a leading module qualifier (interface spelling always qualifies foreign modules).
    if len(parts) > 1:
        parts = parts[1:]
    return ".".join(parts)
