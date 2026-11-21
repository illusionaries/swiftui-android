#!/usr/bin/env python3
"""Retarget an Apple .swiftinterface (from the iOS simulator SDK) to a foreign triple.

Apple's textual module interfaces are *recompiled* for whatever target you build for,
but their embedded `// swift-module-flags` pin the Apple triple, and a handful of
spellings in the text only exist in an ObjC-interop / Darwin compilation.

This script applies a small, closed set of **mechanical** rewrites (listed below) and
otherwise copies the interface byte for byte. No declaration is invented, renamed or
deleted: every `public` API declaration that comes out is exactly Apple's.

Documented rewrites
-------------------
R1  Header metadata: retarget `-target`, drop `-enable-objc-interop` (the Android
    frontend rejects it), blank the `swift-compiler-version` / `-interface-compiler-version`
    pins that otherwise make the compiler refuse a cross-target interface
    ("this SDK is not supported by the compiler").  Availability and API text are
    unaffected.
R2  Drop the self-import `@_exported [public] import <Self>`.  In Apple's SDK that line
    imports the framework's *Clang umbrella module*, which has the same name as the
    Swift module.  There is no Clang module on the port, and a module cannot import
    itself, so the line is removed.
R3  Drop `import <Self>.<submodule>` (same reasoning, dotted form).
R4  `import X.Y` -> `import X`: Clang submodules (`os.log`, `os.lock`, ...) have no
    equivalent; the parent module carries the declarations.
R5  Materialize the Clang-umbrella's implicit dependencies.  A Darwin framework
    interface may reference a module (e.g. `Foundation.URL`) that it only sees because
    its ObjC umbrella header imported it.  Such imports are passed in by the caller
    (`--imports=...`) and inserted after the header; they add no declarations.
R6  `CoreFoundation::<CG scalar>` -> `CoreGraphics::<CG scalar>`.  On Darwin `CGFloat`,
    `CGPoint`, `CGSize`, `CGRect`, `CGVector` and `CGAffineTransform` are declared in
    `CoreFoundation/CFCGTypes.h`, so the interface names them through `CoreFoundation`.
    Android's `CoreFoundation` is the corelibs Clang module, which has no CG types, and
    shadowing it would break `Foundation` (its public API references `CFString`, ...).
    The port's `CoreGraphics` shim declares exactly those six types instead, so the
    qualification is rewritten.  Only the qualifier changes, never the declaration.
R7  Strip `@objc` / `@objc(name)`.  ObjC interop does not exist on Android; the
    attribute only expresses exposure to the ObjC runtime.  Swift signatures are
    unchanged.
R8  Drop `@available(iOS, unavailable)` / `@available(macOS, unavailable)`.  Availability
    for Apple platforms is irrelevant to an Android target and, combined with the
    `AnyAppleOSAvailability` experimental feature, only adds noise.

Usage: retarget_interface.py <in.swiftinterface> <out.swiftinterface> <ModuleName> [--imports=TEXT]
"""
import re
import sys

TARGET = "aarch64-unknown-linux-android28"

# R6: the CG scalar types Apple declares in CoreFoundation/CFCGTypes.h.
CG_SCALAR_TYPES = (
    "CGFloat",
    "CGPoint",
    "CGSize",
    "CGRect",
    "CGVector",
    "CGAffineTransform",
)
CG_SCALAR_RE = re.compile(
    r"\bCoreFoundation::(%s)\b" % "|".join(CG_SCALAR_TYPES)
)

# R7: `@objc` or `@objc(name)`, but not `@objcMembers` / `@objcSomething`.
OBJC_ATTR = re.compile(r"@objc(?![A-Za-z0-9_])(?:\([^)]*\))?\s*")


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--imports=")]
    extra_imports = ""
    for a in sys.argv[1:]:
        if a.startswith("--imports="):
            extra_imports = a[len("--imports="):]
    if len(args) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst, module_name = args

    with open(src, encoding="utf-8") as handle:
        text = handle.read()

    # ---- R1: header metadata ------------------------------------------------
    def rewrite_flags(match: re.Match) -> str:
        flags = match.group(1)
        flags = re.sub(r"-target\s+\S+", f"-target {TARGET}", flags)
        flags = flags.replace("-enable-objc-interop ", "")
        flags = re.sub(r"\s+", " ", flags).strip()
        return "// swift-module-flags: " + flags

    text = re.sub(
        r"^// swift-compiler-version: .*$",
        "// swift-compiler-version: cross-compiled",
        text,
        count=1,
        flags=re.M,
    )
    text = re.sub(r"// swift-module-flags: (.*)", rewrite_flags, text, count=1)

    def rewrite_ignorable(match: re.Match) -> str:
        flags = match.group(1)
        flags = re.sub(r"-interface-compiler-version\s+\S+", "", flags)
        flags = re.sub(r"\s+", " ", flags).strip()
        return "// swift-module-flags-ignorable: " + flags

    text = re.sub(r"// swift-module-flags-ignorable: (.*)", rewrite_ignorable, text, count=1)

    # ---- R2/R3: self-imports ------------------------------------------------
    text = re.sub(
        r"^@_exported (?:public )?import %s\s*$\n?" % re.escape(module_name),
        "",
        text,
        count=1,
        flags=re.M,
    )
    text = re.sub(r"^import %s\.\w+\s*$\n?" % re.escape(module_name), "", text, flags=re.M)

    # ---- R4: dotted Clang submodule imports --------------------------------
    text = re.sub(r"^(@_exported )?import (\w+)\.(\w+)\s*$", r"\1import \2", text, flags=re.M)

    # ---- R5: umbrella-derived imports --------------------------------------
    if extra_imports:
        def insert_after_header(match: re.Match) -> str:
            return match.group(0) + "\n" + extra_imports

        text = re.sub(r"^// swift-module-flags-ignorable: .*$", insert_after_header,
                      text, count=1, flags=re.M)

    # ---- R6: CG scalar type qualification ----------------------------------
    text = CG_SCALAR_RE.sub(r"CoreGraphics::\1", text)

    # ---- R8: Apple-platform availability noise -----------------------------
    text = text.replace("@available(iOS, unavailable)\n", "")
    text = text.replace("@available(macOS, unavailable)\n", "")

    # ---- R7: ObjC annotations ----------------------------------------------
    text = OBJC_ATTR.sub("", text)

    with open(dst, "w", encoding="utf-8") as handle:
        handle.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
