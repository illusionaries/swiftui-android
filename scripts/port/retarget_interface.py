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
R5  Materialize the imports an interface only sees through its Darwin umbrella / SDK
    context.  Several retargeted interfaces reference another module by *qualified name*
    without importing it (`SwiftUICore` names `QuartzCore::CALayer`, `CoreText::CTFont`,
    `ObjectiveC::NSObject`), which works on Darwin because those modules are implicitly
    loadable from the SDK.  On the port a qualified name needs the module imported, so
    every module in PROVIDED_MODULES that is referenced by qualified name and not yet
    imported gets an `import` inserted after the module header.  Extra imports can also
    be forced with `--imports=...`.  No declarations are added.
R6  CG scalar qualification.  On Darwin `CGFloat`, `CGPoint`, `CGSize`, `CGRect`,
    `CGVector` and `CGAffineTransform` are declared in `CoreFoundation/CFCGTypes.h`, so
    the interface names them through `CoreFoundation`.  Android's `CoreFoundation` is
    the corelibs Clang module, which has no CG types, and shadowing it would break
    `Foundation`.  The port's `CoreGraphics` shim declares exactly those six types, so
    `CoreFoundation::<CG scalar>` is requalified to `CoreGraphics::<CG scalar>`.  Only
    the qualifier changes; the declaration does not.
R7  Strip `@objc` / `@objc(name)` / `@nonobjc`.  ObjC interop does not exist on Android;
    the attribute only expresses exposure to the ObjC runtime.  Swift signatures are
    unchanged.
R8  Drop `@available(iOS, unavailable)` / `@available(macOS, unavailable)`.  Availability
    for Apple platforms is irrelevant to an Android target and, combined with the
    `AnyAppleOSAvailability` experimental feature, only adds noise.
R9  Drop `: BitwiseCopyable` conformance clauses.  On Darwin CG geometry types are
    C structs, which are implicitly `BitwiseCopyable`.  On the port they are Swift
    structs from corelibs Foundation, and a retroactive conformance to a *marker*
    protocol is not allowed ("conformance must occur in the same module").  The
    conformance is a codegen hint (SE-0426) with no API surface, so the clause is
    removed.  Documented as a semantic gap in docs/PORT-SDK.md.
R10 Foundation API that the Swift SDK for Android's Foundation does not ship.
    The SDK's Foundation is a reduced build: `LocalizedStringResource`, `NSItemProvider`,
    `UndoManager`, `NSUserActivity`, `NSFileCoordinator`, `FileWrapper`,
    `NSKeyValueChangeKey`, `AttributeRunBoundaries`, `Date.ComponentsFormatStyle`
    (with `Field`), `Date.RelativeFormatStyle` (with `Field`),
    `Locale.Language`, `NumberFormatStyleConfiguration.SignDisplayStrategy`,
    `AttributeScopes.FoundationAttributes` are all absent.  The port declares them in
    the `FoundationShims` module (declarations copied from Apple's shipped
    Foundation.swiftinterface / headers) and requalifies the references.  `URLRequest`
    is *not* re-declared: on Android it lives in the real `FoundationNetworking`
    module, so it is requalified there instead (`Foundation.URLRequest` ->
    `FoundationNetworking.URLRequest`, and `import FoundationNetworking` is added).
R12 Drop `typealias X = @_opaqueReturnTypeOf("<mangled>", 0) __` declarations.  That
    attribute binds a name to an opaque result type of a declaration *in a prebuilt
    binary module*, looked up by mangled symbol.  When a module is recompiled from text
    there is no binary to look the symbol up in ("unable to resolve type for
    _opaqueReturnTypeOf attribute").  Dropping the alias leaves the associated type to be
    inferred from the `some`-typed witness in the same extension — exactly the mechanism
    ordinary SwiftUI code uses with `var body: some View`.  Declaration text is otherwise
    untouched.
R11 Supplement: a module whose Swift interface is pure Swift but which also references
    types Apple only ships in a Clang header (CoreText's `CTFont`, Accessibility's
    `AXChartDescriptor`) gets a declaration-only supplement appended to the interface
    (`--supplement=path`).  The supplement is hand-written from Apple's headers and
    contains no bodies, exactly like the rest of an interface file.

Usage: retarget_interface.py <in.swiftinterface> <out.swiftinterface> <ModuleName>
         [--imports=TEXT] [--supplement=PATH]
"""
import re
import sys

TARGET = "aarch64-unknown-linux-android28"

# ---- R5 ------------------------------------------------------------------
# Modules the Port SDK provides (retargeted or shimmed). A qualified reference such as
# `QuartzCore::CALayer` makes the corresponding module importable in Swift, but the
# module must also be imported for the name to be visible while the interface is
# recompiled, so references to these are turned into imports.
PROVIDED_MODULES = (
    "Accessibility", "Combine", "CoreData", "CoreGraphics", "CoreFoundation",
    "CoreMedia", "CoreText", "CoreTransferable", "DeveloperToolsSupport", "Dispatch",
    "FoundationNetworking", "FoundationShims", "ObjectiveC", "Observation", "OSLog",
    "QuartzCore", "Spatial", "SwiftUI", "SwiftUICore", "Symbols",
    "UniformTypeIdentifiers", "UIKit", "os", "simd",
)

# ---- R6 ------------------------------------------------------------------
CG_SCALAR_TYPES = (
    "CGFloat",
    "CGPoint",
    "CGSize",
    "CGRect",
    "CGVector",
    "CGAffineTransform",
)
# Both spellings of a module-qualified name occur in Apple's interfaces
# (`SwiftUICore` prints `Mod::Name`, `SwiftUI` prints `Mod.Name`).
CORE_FOUNDATION_CG_RE = re.compile(
    r"\bCoreFoundation(::|\.)(%s)\b" % "|".join(CG_SCALAR_TYPES)
)

# ---- R10 -----------------------------------------------------------------
# Longest paths first: a path that is a prefix of another must not win.
FOUNDATION_REQUALIFY = [
    ("Foundation.Date.Foundation.ComponentsFormatStyle.Foundation.Field",
     "FoundationShims.ComponentsFormatStyleField"),
    ("Foundation.Date.Foundation.RelativeFormatStyle.Foundation.Field",
     "FoundationShims.RelativeFormatStyleField"),
    ("Foundation::Date.Foundation::ComponentsFormatStyle.Foundation::Field",
     "FoundationShims.ComponentsFormatStyleField"),
    ("Foundation::Date.Foundation::RelativeFormatStyle.Foundation::Field",
     "FoundationShims.RelativeFormatStyleField"),
    ("Foundation::AttributedString.Foundation::AttributeRunBoundaries",
     "FoundationShims.AttributeRunBoundaries"),
    ("Foundation::NumberFormatStyleConfiguration.Foundation::SignDisplayStrategy",
     "FoundationShims.SignDisplayStrategy"),
    ("Foundation::AttributeScopes.Foundation::FoundationAttributes",
     "FoundationShims.FoundationAttributes"),
    ("Foundation::Date.Foundation::ComponentsFormatStyle",
     "FoundationShims.ComponentsFormatStyle"),
    ("Foundation::Date.Foundation::RelativeFormatStyle",
     "FoundationShims.RelativeFormatStyle"),
    ("Foundation::Locale.Foundation::Language", "FoundationShims.Language"),
    ("Foundation.URLRequest", "FoundationNetworking.URLRequest"),
    ("Foundation::URLRequest", "FoundationNetworking.URLRequest"),
    ("Foundation.LocalizedStringResource", "FoundationShims.LocalizedStringResource"),
    ("Foundation::LocalizedStringResource", "FoundationShims.LocalizedStringResource"),
    ("Foundation.NSItemProvider", "FoundationShims.NSItemProvider"),
    ("Foundation.NSUserActivity", "FoundationShims.NSUserActivity"),
    ("Foundation.NSFileCoordinator", "FoundationShims.NSFileCoordinator"),
    ("Foundation.NSKeyValueChangeKey", "FoundationShims.NSKeyValueChangeKey"),
    ("Foundation.FileWrapper", "FoundationShims.FileWrapper"),
    ("Foundation.UndoManager", "FoundationShims.UndoManager"),
]

# ---- R7 ------------------------------------------------------------------
OBJC_ATTR = re.compile(r"@objc(?![A-Za-z0-9_])(?:\([^)]*\))?\s*|@nonobjc\s*")

# ---- R9 ------------------------------------------------------------------
BITWISE_COPYABLE_RE = re.compile(r"\s*,\s*BitwiseCopyable\b|\bBitwiseCopyable\s*,\s*|\bBitwiseCopyable\b")


def main() -> int:
    paths = []
    extra_imports = ""
    supplement = ""
    for a in sys.argv[1:]:
        if a.startswith("--imports="):
            extra_imports = a[len("--imports="):]
        elif a.startswith("--supplement="):
            supplement = a[len("--supplement="):]
        else:
            paths.append(a)
    if len(paths) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst, module_name = paths

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
    text = re.sub(r"^import %s\.\w+\s*$\n?" % re.escape(module_name), "", text,
                  flags=re.M)

    # ---- R4: dotted Clang submodule imports --------------------------------
    text = re.sub(r"^(@_exported )?import (\w+)\.(\w+)\s*$", r"\1import \2", text, flags=re.M)

    # ---- R6: CG scalar type qualification ----------------------------------
    text = CORE_FOUNDATION_CG_RE.sub(r"CoreGraphics\1\2", text)

    # ---- R10: Foundation API absent from the Android SDK -------------------
    for old, new in FOUNDATION_REQUALIFY:
        text = text.replace(old, new)

    # ---- R5: materialize qualified-module references as imports ------------
    imported = set(re.findall(r"^(?:@_exported )?(?:public )?import (\w+)", text, re.M))
    referenced = set(re.findall(r"(?<![\w.])([A-Z]\w*)(?:::|(?=\.)[.])", text))
    needed = sorted((referenced & set(PROVIDED_MODULES)) - imported - {module_name})
    added = "\n".join(f"import {m}" for m in needed)
    if extra_imports:
        added = (added + "\n" + extra_imports).strip()
    if added:
        def insert_after_header(match: re.Match) -> str:
            return match.group(0) + "\n" + added

        text = re.sub(r"^// swift-module-flags-ignorable: .*$", insert_after_header,
                      text, count=1, flags=re.M)

    # ---- R8: Apple-platform availability noise -----------------------------
    text = text.replace("@available(iOS, unavailable)\n", "")
    text = text.replace("@available(macOS, unavailable)\n", "")

    # ---- R9: BitwiseCopyable conformance clauses ---------------------------
    # A conformance-only extension (`extension X : BitwiseCopyable {}`) is dropped
    # whole; a clause inside a conformance list is removed from the list.
    mod = r"(?:[A-Za-z_]\w*(?:::|\\.))*"
    text = re.sub(
        r"(?:^@[^\n]*\n)*^extension [^\n{]*:\s*" + mod + r"BitwiseCopyable\s*\{\s*\}\s*$\n?",
        "",
        text,
        flags=re.M,
    )
    text = re.sub(r",\s*" + mod + r"BitwiseCopyable\b", "", text)
    text = re.sub(r"([:,(])\s*" + mod + r"BitwiseCopyable\s*,\s*", r"\1 ", text)
    text = re.sub(r":\s*" + mod + r"BitwiseCopyable\s*(?=[{,\s])", " ", text)
    # A trailing block of attributes whose declaration was the dropped conformance.
    text = re.sub(r"(?:^@[^\n]*\n)+\s*$", "", text)

    # ---- R12: opaque-return-type aliases -----------------------------------
    text = re.sub(
        r"(?:^\s*@[^\n]*\n)*^\s*[^\n]*\btypealias \w+ = @_opaqueReturnTypeOf\([^\n]*__[^\n]*$\n?",
        "",
        text,
        flags=re.M,
    )

    # ---- R7: ObjC annotations ----------------------------------------------
    text = OBJC_ATTR.sub("", text)

    # ---- R11: supplement ----------------------------------------------------
    if supplement:
        with open(supplement, encoding="utf-8") as handle:
            text = text.rstrip("\n") + "\n\n// MARK: - port supplement (see docs/PORT-SDK.md)\n" + handle.read()

    with open(dst, "w", encoding="utf-8") as handle:
        handle.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
