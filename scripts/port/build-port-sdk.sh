#!/usr/bin/env bash
#
# build-port-sdk.sh — build the "Port SDK": Apple's *real* SwiftUI module interfaces,
# retargeted to Android, plus the minimal platform shims they need.
#
# Why this exists
# ---------------
# SwiftUI/SwiftUICore ship only as closed-source binaries for Darwin. Apple does publish
# their complete API as textual module interfaces (.swiftinterface) inside the iOS SDK.
# Those interfaces are recompiled by the Swift frontend for whatever target you build
# for; only their embedded `-target` header pins them to Apple. This script retargets the
# header, supplies shims for Apple-only modules (UIKit, CoreGraphics, ...), and thereby
# produces importable `SwiftUI`/`SwiftUICore` modules for aarch64 Android whose
# declarations are byte-identical to Apple's.
#
# Output: build/port-sdk/gen/<Module>.swiftmodule/*.swiftinterface
#         build/port-sdk/shims/<Module>.swiftmodule/*.swiftinterface
#
# Usage: scripts/port/build-port-sdk.sh [--clean] [--no-probe]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
port_dir="$ROOT/scripts/port"
out="$ROOT/build/port-sdk"
gen="$out/gen"
shims="$out/shims"

: "${APPLE_SDK:=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk}"
: "${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN}"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
: "${SWIFT_ANDROID_SDK:=$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.4.3-RELEASE_android.artifactbundle/swift-android}"
: "${TARGET_TRIPLE:=aarch64-unknown-linux-android28}"

export PATH="$SWIFT_TOOLCHAIN/usr/bin:$PATH"

# SwiftUI's `@State`/`@Preview` are *macros*: the interface declares
# `#externalMacro(module: "SwiftUIMacros", type: "StateMacro")`, and the implementation is a
# host-side compiler plugin (a macOS dylib) that emits Swift source — it never runs on the
# target. Xcode ships it in the platform's `usr/lib/swift/host/plugins`, and the plugin
# server is part of the OSS toolchain, so macro expansion works for a cross-compiled
# Android build. Look in the SDK first, then the platform directories.
macro_plugin_dir=""
for candidate in \
    "$APPLE_SDK/usr/lib/swift/host/plugins" \
    "$(dirname "$(dirname "$(dirname "$APPLE_SDK")")")/usr/lib/swift/host/plugins" \
    "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins" \
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"; do
    if [ -d "$candidate" ] && ls "$candidate"/*.dylib >/dev/null 2>&1; then
        macro_plugin_dir="$candidate"
        break
    fi
done
plugin_flags=()
if [ -n "$macro_plugin_dir" ] && [ -x "$SWIFT_TOOLCHAIN/usr/bin/swift-plugin-server" ]; then
    plugin_flags=(-external-plugin-path "$macro_plugin_dir#$SWIFT_TOOLCHAIN/usr/bin/swift-plugin-server")
fi
resource_dir="$SWIFT_ANDROID_SDK/swift-resources/usr/lib/swift-aarch64"
ndk_sysroot="$SWIFT_ANDROID_SDK/ndk-sysroot"

[ -d "$resource_dir" ] || { echo "error: Swift SDK for Android not installed (looked for $resource_dir)" >&2; exit 2; }
[ -d "$ndk_sysroot" ]  || { echo "error: NDK sysroot missing; run the SDK's scripts/setup-android-sdk.sh with ANDROID_NDK_HOME=$ANDROID_NDK_HOME" >&2; exit 2; }
[ -d "$APPLE_SDK" ]    || { echo "error: iOS simulator SDK not found at $APPLE_SDK" >&2; exit 2; }

clean=0
probe=1
for arg in "$@"; do
    case "$arg" in
        --clean) clean=1 ;;
        --no-probe) probe=0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ "$clean" = 1 ]; then rm -rf "$gen" "$shims"; fi
mkdir -p "$gen" "$shims"

# Modules whose interface Apple actually ships; these are retargeted verbatim.
real_modules=(SwiftUICore SwiftUI Symbols Combine DeveloperToolsSupport)
# Imports that a Darwin interface only sees through its framework's ObjC umbrella
# header (which does not exist on the port). `retarget_interface.py --imports` inserts
# these after the module header; they add no declarations, only visibility.
declare -A umbrella_imports=(
    [SwiftUICore]="import CoreGraphics"
)
# Modules that do not exist on Android; port-shims/<Module>/<Module>.swift declares the
# subset of their API that the retargeted interfaces reference.
# Ordered by dependency: every shim is built after the shims it imports.
shim_modules=(UniformTypeIdentifiers FoundationShims ObjectiveC UIUtilities CoreGraphics QuartzCore CoreText CoreTransferable Accessibility Spatial simd Darwin OSLog os DataDetection CoreMedia CoreData UIKit)

retarget() {
    local module="$1"
    local iface="$APPLE_SDK/System/Library/Frameworks/$module.framework/Modules/$module.swiftmodule/arm64-apple-ios-simulator.swiftinterface"
    if [ ! -f "$iface" ]; then
        echo "  ! no interface for $module (skipping retarget)"
        return 1
    fi
    local extra=""
    if [ -n "${umbrella_imports[$module]:-}" ]; then
        extra="--imports=${umbrella_imports[$module]}"
    fi
    mkdir -p "$gen/$module.swiftmodule"
    rm -f "$gen/$module.swiftmodule"/*.swiftinterface
    # The loader looks for the interface under several target-derived names; provide all.
    for name in aarch64 aarch64-unknown-linux-android "$TARGET_TRIPLE"; do
        python3 "$port_dir/retarget_interface.py" "$iface" "$gen/$module.swiftmodule/$name.swiftinterface" "$module" ${extra:+"$extra"}
    done
    return 0
}

build_shim() {
    local module="$1"
    local src="$ROOT/port-shims/$module/$module.swift"
    [ -f "$src" ] || { echo "  ! no shim source for $module"; return 0; }
    mkdir -p "$shims/$module.swiftmodule"
    rm -f "$shims/$module.swiftmodule"/*.swiftmodule
    local iface_tmp="$out/.tmp-$module.swiftinterface"
    if ! swiftc -emit-module -parse-as-library "$src" -module-name "$module" -target "$TARGET_TRIPLE" \
        -resource-dir "$resource_dir" -sdk "$ndk_sysroot" -I "$shims" -I "$gen" -swift-version 5 \
        -enable-library-evolution -emit-module-interface-path "$iface_tmp" \
        -emit-module-path "$out/.tmp-$module.swiftmodule" \
        -module-cache-path "$out/.module-cache" 2>"$out/.shim-$module.log"; then
        echo "  ✗ shim $module failed:"
        grep -E "error:" "$out/.shim-$module.log" | head -5 | sed 's/^/      /'
        return 1
    fi
    for name in aarch64 aarch64-unknown-linux-android "$TARGET_TRIPLE"; do
        cp "$iface_tmp" "$shims/$module.swiftmodule/$name.swiftinterface"
    done
    return 0
}

echo "→ retargeting Apple interfaces to $TARGET_TRIPLE"
for module in "${real_modules[@]}"; do
    if retarget "$module"; then echo "  ✓ $module"; fi
done

echo "→ building platform shims"
for module in "${shim_modules[@]}"; do
    build_shim "$module" || true
done

if [ "$probe" = 1 ]; then
    echo "→ probing: can a SwiftUI app compile for Android? (macro plugins: ${macro_plugin_dir:-none})"
    rm -rf "$out/.module-cache"
    set +e
    swiftc -typecheck "$port_dir/probe.swift" -module-name PortProbe -target "$TARGET_TRIPLE" \
        -resource-dir "$resource_dir" -sdk "$ndk_sysroot" -I "$gen" -I "$shims" \
        -module-cache-path "$out/.module-cache" -enable-experimental-feature AnyAppleOSAvailability \
        "${plugin_flags[@]}" \
        -swift-version 5 >"$out/probe.log" 2>&1
    status=$?
    set -e
    errors=$(grep -c "error:" "$out/probe.log" || true)
    echo "  probe errors: $errors (log: build/port-sdk/probe.log)"
    if [ "$status" != 0 ]; then
        grep "error:" "$out/probe.log" | head -20 | sed -E 's@.*/(gen|shims)/@@' | sed 's/^/      /'
    fi
fi
