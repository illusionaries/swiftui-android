#!/usr/bin/env python3
"""Remove `$`-prefixed projected-value declarations from generated interface sources.

Why this pass exists
--------------------
Apple's `.swiftinterface` lists a property's *projected value* explicitly, e.g.

    public var isOn: SwiftUICore.Binding<Swift.Bool>      // the wrapped property
    public var $isOn: SwiftUICore.Binding<Swift.Bool> { get }

`$isOn` is normally *synthesized* by the compiler from the property wrapper on `isOn`.
Recompiling the interface as source therefore cannot declare `$isOn` literally:

  * Swift rejects the name outright — "cannot declare entity named '$isOn'; the '$' prefix is
    reserved for implicitly-synthesized declarations"; and
  * with the wrapper declared, the frontend *crashes* while resolving the property-wrapper
    auxiliary variable for that name (Swift 6.4.3, TypeCheckPrimaryFileRequest).

Dropping the declaration is not a loss of API: the projection still exists, synthesized from
the wrapped property, which is exactly what Apple's interface documents. If a wrapped property
is not present for some type, its projection simply does not exist — the same as writing that
type in Swift source.

Usage: strip_projected_vars.py <file.swift> [<file.swift> ...]
Prints how many declarations were removed per file. Idempotent.
"""
import sys


def strip(text: str) -> tuple[str, int]:
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    removed = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        # A declaration line that names a `$`-prefixed member.
        if "var $" in line or "let $" in line:
            # Walk back over contiguous attribute lines that belong to this declaration.
            start_attributes = len(out)
            while start_attributes > 0:
                previous = out[start_attributes - 1].strip()
                if previous.startswith("@") or (previous.startswith("//") and "port:" in previous):
                    start_attributes -= 1
                else:
                    break
            # Remove the declaration through its matching closing brace.
            depth = 0
            saw_brace = False
            while i < len(lines):
                current = lines[i]
                for char in current:
                    if char == "{":
                        depth += 1
                        saw_brace = True
                    elif char == "}":
                        depth -= 1
                i += 1
                if saw_brace and depth == 0:
                    break
            del out[start_attributes:]
            removed += 1
            continue
        out.append(line)
        i += 1
    return "".join(out), removed


# Property wrappers cannot be applied to a declaration that already spells out its own
# accessors, which is exactly the shape an interface produces (`@Binding public var isOn: Bool
# { get }`). Swift 6.4.3 additionally *crashes* resolving the wrapper's auxiliary variable for
# such a declaration. The port supplies wrapper semantics in the engine, so the attribute is
# dropped and the stored declaration becomes a plain computed one.
WRAPPER_ATTRS = (
    "State", "Binding", "StateObject", "ObservedObject", "EnvironmentObject", "Environment",
    "Published", "AppStorage", "SceneStorage", "FocusState", "Namespace", "GestureState",
    "FetchRequest", "ScalarUniform", "_projectedValueProperty",
)


def strip_wrapper_attributes(text: str) -> tuple[str, int]:
    import re
    pattern = re.compile(
        r"^[ \t]*@(?:[A-Za-z_][A-Za-z0-9_]*\.)?" r"(?:" + "|".join(WRAPPER_ATTRS) + r")"
        r"(?:\([^)]*\)|<[^>]*>)?" r"[ \t]*",
        re.MULTILINE,
    )
    removed = 0
    while True:
        updated, count = pattern.subn("", text, count=1)
        if count == 0:
            break
        text = updated
        removed += 1
    # Inline occurrences directly preceding the declaration.
    inline = re.compile(
        r"@(?:[A-Za-z_][A-Za-z0-9_]*\.)?" r"(?:" + "|".join(WRAPPER_ATTRS) + r")(?:\([^)]*\))?" r"(?=[ \t]+public|\s*\n)"
    )
    text, inline_count = inline.subn("", text)
    return text, removed + inline_count


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    for path in argv[1:]:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        stripped, removed = strip(text)
        stripped, wrappers = strip_wrapper_attributes(stripped)
        if removed or wrappers:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(stripped)
        print(f"{path}: removed {removed} projected-value declaration(s), "
              f"{wrappers} property-wrapper attribute(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
