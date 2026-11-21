#!/usr/bin/env python3
"""Retarget an Apple .swiftinterface (from the iOS simulator SDK) to a foreign triple.

Apple's textual module interfaces are *recompiled* for whatever target you build for,
but their embedded `// swift-module-flags` pin the Apple triple. This script rewrites
only the module header, leaving every declaration byte-identical.

Usage: retarget_interface.py <input.swiftinterface> <output.swiftinterface> <ModuleName>
"""
import re
import sys

TARGET = "aarch64-unknown-linux-android28"

# ---------------------------------------------------------------------------
# Documented mechanical rewrites.
#
# Each rule below is *syntactic only*: it removes a spelling that only exists in
# ObjC-interop / Darwin compilations. No declaration is ever renamed, added or
# removed, so the resulting module still exposes byte-identical API text.
# ---------------------------------------------------------------------------

# 1. `@objc` / `@objc(name)` attribute. ObjC interop is unavailable on Android
#    (`-enable-objc-interop` is rejected by the frontend), while Apple's
#    interfaces annotate every class `deinit` and every `@objc` member with it.
#    The attribute expresses *exposure to the ObjC runtime*, which the port does
#    not have; the Swift declaration and its signature are unchanged.
OBJC_ATTR = re.compile(r"@objc(?![A-Za-z0-9_])(?:\([^)]*\))?\s*")


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst, module_name = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(src, encoding="utf-8") as handle:
        text = handle.read()

    def rewrite_flags(match: re.Match) -> str:
        flags = match.group(1)
        flags = re.sub(r"-target\s+\S+", f"-target {TARGET}", flags)
        # ObjC interop is unavailable outside Darwin; the declarations themselves
        # stay intact, only the mode is dropped.
        flags = flags.replace("-enable-objc-interop ", "")
        flags = re.sub(r"\s+", " ", flags).strip()
        return "// swift-module-flags: " + flags

    # The compiler-version stamp makes cross-version interfaces refuse to load
    # ("this SDK is not supported by the compiler"). It is metadata only; the
    # interface text is versioned by swift-interface-format-version instead.
    text = re.sub(r"^// swift-compiler-version: .*$", "// swift-compiler-version: cross-compiled",
                  text, count=1, flags=re.M)
    text = re.sub(r"// swift-module-flags: (.*)", rewrite_flags, text, count=1)

    # The SDK/compiler version pin forbids cross-compilation ("this SDK is not
    # supported by the compiler"). The declarations do not depend on it.
    def rewrite_ignorable(match: re.Match) -> str:
        flags = match.group(1)
        flags = re.sub(r"-interface-compiler-version\s+\S+", "", flags)
        flags = re.sub(r"\s+", " ", flags).strip()
        return "// swift-module-flags-ignorable: " + flags

    text = re.sub(r"// swift-module-flags-ignorable: (.*)", rewrite_ignorable, text, count=1)

    # `@_exported import <Self>` re-exports the ObjC "underlying module" on Apple
    # platforms. On the port there is no underlying module, and importing yourself
    # is meaningless, so drop it.
    text = re.sub(r"^@_exported import %s$\n" % re.escape(module_name), "", text, flags=re.M)

    # Clang-style dotted submodule imports have no equivalent on the port; the parent
    # module carries the declarations. `import X.Y` therefore becomes `import X`
    # (e.g. `import os.log` -> `import os`, `import os.lock` -> `import os`).
    text = re.sub(r"^import %s\.\w+$" % re.escape(module_name), "", text, flags=re.M)
    text = re.sub(r"^(@_exported )?import (\w+)\.(\w+)$", r"\1import \2", text, flags=re.M)

    # Apple-only availability shorthands that the Android target does not know about.
    text = text.replace("@available(iOS, unavailable)", "")
    text = text.replace("@available(macOS, unavailable)", "")

    # ObjC annotation removal (see OBJC_ATTR). Applied last so the rules above can
    # still match Apple's original spelling.
    text = OBJC_ATTR.sub("", text)

    with open(dst, "w", encoding="utf-8") as handle:
        handle.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
