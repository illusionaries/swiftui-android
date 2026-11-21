#!/usr/bin/env bash
#
# gallery.sh — build and run the second demo app: the SwiftUI control gallery.
#
# The gallery is a standalone app, not a screen inside Atlas: it is compiled as
# dev.swiftui.android.gallery (its own launcher icon, next to the Atlas demo) so you can have both
# installed at once and switch between them from the launcher.
#
# Usage:
#   scripts/gallery.sh                 # release build, arm64, install + launch + screenshot
#   scripts/gallery.sh --debug         # debug build (faster compile, slower at runtime)
#   scripts/gallery.sh --no-install    # only build build/SwiftUI-Gallery.apk
#   scripts/gallery.sh --abi x86_64    # target the x86_64 emulator image
#   scripts/gallery.sh --no-build      # repackage the existing libSwiftUIAndroidApp.so
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# What makes this the gallery: Package.swift compiles Sources/DemoApp with -DPORT_DEMO_GALLERY,
# so SwiftUIHostScene hosts ControlGallery() instead of the Atlas app.
export SWIFTUI_DEMO_GALLERY=1

# SWIFTUI_UI_DEBUG=1 compiles the demo's on-screen diagnostics (last tap, node path under it, scroll
# model). They answer "why did that tap do nothing?" on a build that cannot be debugged.
UI_DEBUG=0
if [ "${SWIFTUI_UI_DEBUG:-0}" = "1" ]; then
    UI_DEBUG=1
fi

CONFIG=release
ABI=arm64-v8a
TRIPLE=aarch64-unknown-linux-android28
INSTALL=1
DO_BUILD=1

while [ $# -gt 0 ]; do
    case "$1" in
        --debug) CONFIG=debug ;;
        --release) CONFIG=release ;;
        --abi) ABI="$2"; shift ;;
        --triple) TRIPLE="$2"; shift ;;
        --no-install) INSTALL=0 ;;
        --no-build) DO_BUILD=0 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# The official OSS toolchain is required: Xcode's Swift cannot target Android.
SWIFT_TC="${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN}"
if [ -x "$SWIFT_TC/usr/bin/swift" ]; then
    export PATH="$SWIFT_TC/usr/bin:$PATH"
fi
# Prefer the NDK r30 this project was set up against (an older session NDK breaks the Swift SDK).
ndk_version() { [ -f "$1/source.properties" ] && grep -E '^Pkg.Revision' "$1/source.properties" | cut -d' ' -f3 | cut -d. -f1 || echo 0; }
DEFAULT_NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
if [ -z "${ANDROID_NDK_HOME:-}" ] || [ "$(ndk_version "$ANDROID_NDK_HOME")" -lt 27 ]; then
    ANDROID_NDK_HOME="$DEFAULT_NDK"
fi
export ANDROID_NDK_HOME
echo "▸ ndk: $ANDROID_NDK_HOME ($(ndk_version "$ANDROID_NDK_HOME"))"

if [ "$DO_BUILD" = 1 ]; then
    echo "▸ swift: $(command -v swift) — $(swift --version 2>/dev/null | head -1)"
    echo "▸ building the control gallery ($CONFIG, $TRIPLE)"
    touch Package.swift   # the manifest declares different targets per mode; force re-evaluation
    # shellcheck source=scripts/port/plugin-flags.sh
    source "$ROOT/scripts/port/plugin-flags.sh"
    mkdir -p build/tmp
    LOG=build/tmp/gallery-swift-build.log
    # Check the compiler's exit status, not grep's: a piped filter hides the failure and the
    # packaging step then quietly ships the previous (Atlas) library.
    EXTRA_FLAGS=()
    if [ "$UI_DEBUG" = "1" ]; then
        EXTRA_FLAGS=(-Xswiftc -DPORT_UI_DEBUG)
    fi
    if ! swift build "${PORT_PLUGIN_FLAGS[@]}" "${EXTRA_FLAGS[@]}" -c "$CONFIG" --product SwiftUIAndroidApp \
            --swift-sdk swift-6.4.3-RELEASE_android --triple "$TRIPLE" >"$LOG" 2>&1; then
        grep -E "error:" "$LOG" | head -20 >&2 || tail -30 "$LOG" >&2
        echo "✗ swift build failed — full log: $LOG" >&2
        exit 3
    fi
    grep -E "warning: unre|Build complete" "$LOG" | tail -3
    SO=$(find .build/out -name "libSwiftUIAndroidApp.so" -newer Package.swift 2>/dev/null | head -1)
    [ -n "$SO" ] || SO=$(find .build/out -name "libSwiftUIAndroidApp.so" | head -1)
else
    SO=$(find .build/out -name "libSwiftUIAndroidApp.so" | head -1)
fi
[ -n "${SO:-}" ] && [ -f "$SO" ] || { echo "no libSwiftUIAndroidApp.so; run without --no-build" >&2; exit 1; }

# Guard against a stale Atlas build silently being packaged as the gallery: the demo title is a
# string literal in the shipped library. (Written to a file first: `grep -q` closes the pipe early,
# and under `pipefail` the resulting SIGPIPE would make this check fail on a good build.)
STRINGS_DUMP="$ROOT/build/tmp/gallery-strings.txt"
mkdir -p "$(dirname "$STRINGS_DUMP")"
strings "$SO" > "$STRINGS_DUMP" 2>/dev/null || true
if ! grep -q "Control Gallery" "$STRINGS_DUMP"; then
    echo "✗ $SO does not contain the control gallery (stale build?)" >&2
    echo "  fix: rm -rf .build/out && re-run scripts/gallery.sh" >&2
    exit 1
fi
echo "▸ product: $SO"

SWIFT_LIB_SO="$ROOT/$SO" ./scripts/build-apk.sh --demo gallery --abi "$ABI"

if [ "$INSTALL" = 1 ]; then
    echo "▸ device test"
    ./scripts/device-test.sh --pkg dev.swiftui.android.gallery build/SwiftUI-Gallery.apk || {
        echo "▸ device test FAILED (see evidence above)" >&2
        exit 1
    }
fi
