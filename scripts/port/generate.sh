#!/usr/bin/env bash
#
# generate.sh — regenerate Sources/SwiftUI/Generated/*.swift from Apple's retargeted module
# interfaces and cross-compile-check the result for aarch64-unknown-linux-android28.
#
# Pipeline
# --------
#   1. scripts/port/build-port-sdk.sh  (once)  -> build/port-sdk/gen/<Module>.swiftmodule/
#   2. scripts/port/inject_bodies.py  (here)   -> Sources/SwiftUI/Generated/{SwiftUICore,SwiftUI}.swift
#                                                + build/port-sdk/injected-bodies.json
#   3. swiftc -typecheck               (here)   -> every generated body/attribute problem
#
# The generated files are committed; this script is deterministic (run it twice and `git diff`
# must be empty). `--check` verifies that instead of writing.
#
# Usage:
#   scripts/port/generate.sh                 # regenerate + typecheck
#   scripts/port/generate.sh --no-build      # regenerate only
#   scripts/port/generate.sh --check         # verify generated files are up to date
#   scripts/port/generate.sh --emit-module   # typecheck + emit a real .swiftmodule
#
# Environment overrides (defaults match the pinned toolchain):
#   SWIFT_TOOLCHAIN   swift-6.4.3-RELEASE-osx-package.pkg/Payload
#   SWIFT_ANDROID_SDK swift-6.4.3-RELEASE_android.artifactbundle/swift-android
#   TARGET_TRIPLE     aarch64-unknown-linux-android28
#
# Exit status: 0 only when the generator ran and no error originates in Sources/SwiftUI/Generated/.
# Errors caused by missing/incomplete platform shims are reported separately and do not fail the
# run (they are another workstream: scriptshims are owned by the Port SDK agent).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
port_dir="$ROOT/scripts/port"
gen_src="$ROOT/Sources/SwiftUI/Generated"
port_sdk="$ROOT/build/port-sdk"
gen_dir="$port_sdk/gen"
shims_dir="$port_sdk/shims"
cache_dir="$port_sdk/.module-cache-bodies"

# Toolchain and Swift SDK for Android come from scripts/env.sh (environment -> scripts/local.env
# -> conventional install locations); no machine-specific path is committed.
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
port_env_need swift sdk
: "${TARGET_TRIPLE:=aarch64-unknown-linux-android}"
resource_dir="$SWIFT_ANDROID_SDK/swift-resources/usr/lib/swift-aarch64"
ndk_sysroot="$SWIFT_ANDROID_SDK/ndk-sysroot"

mode=build
emit_module=0
for arg in "$@"; do
    case "$arg" in
        --no-build) mode=generate ;;
        --check) mode=check ;;
        --emit-module) emit_module=1 ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "generate.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[ -d "$resource_dir" ] || { echo "error: Swift SDK for Android not installed (looked for $resource_dir)" >&2; exit 2; }
[ -d "$ndk_sysroot" ] || { echo "error: NDK sysroot missing in $SWIFT_ANDROID_SDK" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. Generate
# ---------------------------------------------------------------------------
echo "→ regenerating Sources/SwiftUI/Generated/ from $gen_dir"
generate_args=(--gen-dir "$gen_dir")
if [ "$mode" = check ]; then generate_args+=(--check); fi
if ! python3 "$port_dir/inject_bodies.py" "${generate_args[@]}"; then
    status=$?
    if [ "$mode" = check ]; then
        echo "error: generated sources are stale; run scripts/port/generate.sh" >&2
    else
        echo "error: generator failed (see above)" >&2
    fi
    exit "$status"
fi
if [ "$mode" = check ]; then
    echo "✓ generated sources are up to date"
    exit 0
fi
if [ "$mode" = generate ]; then
    echo "✓ regenerated (build skipped: --no-build)"
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Type-check the generated module
# ---------------------------------------------------------------------------
if [ ! -d "$gen_dir" ]; then
    echo "error: $gen_dir is missing; run scripts/port/build-port-sdk.sh first" >&2
    exit 2
fi

seam="$ROOT/Sources/SwiftUI/Engine/PortRuntime.swift"
[ -f "$seam" ] || { echo "error: missing engine seam $seam" >&2; exit 2; }

log="$port_sdk/generate.log"
extra_flags=()
if [ "$emit_module" = 1 ]; then
    mkdir -p "$port_sdk/build"
    extra_flags+=(-emit-module-path "$port_sdk/build/SwiftUI.swiftmodule")
else
    extra_flags+=(-typecheck)
fi

# The generated module is named `SwiftUI`, and it also contains Apple's SwiftUICore
# declarations. The Port SDK contains prebuilt interfaces under those very module names, so
# putting build/port-sdk/gen directly on the include path makes the compiler load a second
# `SwiftUI`/`SwiftUICore` module (it then reports e.g. "ambiguous type name 'AnimatableData'
# in 'CGPoint'"). Stage a dependency directory without them.
deps_dir="$port_sdk/deps"
rm -rf "$deps_dir"
mkdir -p "$deps_dir"
for module_dir in "$gen_dir"/*.swiftmodule; do
    module_name="$(basename "$module_dir" .swiftmodule)"
    case "$module_name" in
        SwiftUI|SwiftUICore) continue ;;
    esac
    ln -s "$module_dir" "$deps_dir/$module_name.swiftmodule"
done

echo "→ type-checking Generated/*.swift + Engine/PortRuntime.swift for $SWIFT_TARGET"
set +e
swiftc "${extra_flags[@]}" -parse-as-library \
    "$gen_src"/SwiftUICore.swift "$gen_src"/SwiftUI.swift "$seam" \
    -module-name SwiftUI -target "$SWIFT_TARGET" \
    -resource-dir "$resource_dir" -sdk "$ndk_sysroot" \
    -I "$deps_dir" -I "$shims_dir" \
    -swift-version 5 -enable-experimental-feature AnyAppleOSAvailability \
    -package-name SwiftUI -module-cache-path "$cache_dir" \
    >"$log" 2>&1
status=$?
set -e

# ---------------------------------------------------------------------------
# 3. Attribute the diagnostics
# ---------------------------------------------------------------------------
generated_root="$gen_src/"
generated_errors=0
shim_errors=0
other_errors=0
missing_modules=""

# `error:` lines carry the file that owns them when the diagnostic is local; notes are indented.
while IFS= read -r line; do
    case "$line" in
        *"error: "*)
            case "$line" in
                # A cascade ("failed to build module UIKit ... due to the errors above") is
                # reported on the import line in the generated file; the cause is a shim.
                *"failed to build module"*)
                    shim_errors=$((shim_errors + 1))
                    ;;
                "$generated_root"*)
                    generated_errors=$((generated_errors + 1))
                    ;;
                *"no such module"*|*"could not find module"*)
                    shim_errors=$((shim_errors + 1))
                    missing_modules+="$(printf '%s' "$line" | sed -E "s/.*(no such|could not find) module '([^']+)'.*/\2/") "
                    ;;
                *)
                    shim_errors=$((shim_errors + 1))
                    ;;
            esac
            ;;
    esac
done <"$log"

crash=0
grep -q 'failed due to signal\|Segmentation fault' "$log" && crash=1

echo
if [ "$crash" = 1 ]; then
    echo "✗ the compiler crashed (see $log)"
    tail -3 "$log" | sed 's/^/    /'
fi
if [ "$generated_errors" = 0 ] && [ "$crash" = 0 ]; then
    echo "✓ no errors originate in Sources/SwiftUI/Generated/ (generated code type-checks)"
else
    echo "✗ $generated_errors error(s) originate in Sources/SwiftUI/Generated/:"
    grep -E "^$generated_root.*error:" "$log" | head -20 | sed 's/^/    /'
fi

if [ "$shim_errors" != 0 ]; then
    echo "  $shim_errors diagnostic(s) from the Port SDK (shim gaps, not generated code):"
    if [ -n "$missing_modules" ]; then
        echo "    missing shim module(s): $(printf '%s\n' $missing_modules | sort -u | tr '\n' ' ')"
    fi
    grep 'error:' "$log" | grep -v "^$generated_root" | sed -E 's@^.*/@@' | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'
fi
echo "  full log: $(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$log" "$ROOT")"

if [ "$status" = 0 ]; then
    echo "✓ cross-compilation succeeded"
    exit 0
fi
[ "$generated_errors" = 0 ] && [ "$crash" = 0 ] && exit 0
exit 1
