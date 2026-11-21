#!/usr/bin/env bash
#
# dev.sh — one-command inner loop for the port: cross-compile Swift → package APK → install →
# launch → screenshot. Use it while iterating on the engine instead of running the pieces by hand.
#
# Usage:
#   scripts/dev.sh                 # release build, arm64, install + launch + screenshot
#   scripts/dev.sh --debug         # debug build (faster compile, slower at runtime)
#   scripts/dev.sh --no-install    # only build the APK
#   scripts/dev.sh --abi x86_64    # target the x86_64 emulator image
#   scripts/dev.sh --dummy         # package without Swift (bridge-only smoke test)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG=release
ABI=arm64-v8a
TRIPLE=aarch64-unknown-linux-android28
INSTALL=1
DUMMY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --debug) CONFIG=debug ;;
        --release) CONFIG=release ;;
        --abi) ABI="$2"; shift ;;
        --triple) TRIPLE="$2"; shift ;;
        --no-install) INSTALL=0 ;;
        --dummy) DUMMY=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# The official OSS toolchain is required: Xcode's Swift cannot target Android.
SWIFT_TC="${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN}"
if [ -x "$SWIFT_TC/usr/bin/swift" ]; then
    export PATH="$SWIFT_TC/usr/bin:$PATH"
fi
# Prefer the NDK r30 this project was set up against. The session may export an older
# ANDROID_NDK_HOME (e.g. ndk-bundle 25.x), which SwiftPM rejects for the Android SDK.
ndk_version() { [ -f "$1/source.properties" ] && grep -E '^Pkg.Revision' "$1/source.properties" | cut -d' ' -f3 | cut -d. -f1 || echo 0; }
DEFAULT_NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
if [ -z "${ANDROID_NDK_HOME:-}" ] || [ "$(ndk_version "$ANDROID_NDK_HOME")" -lt 27 ]; then
    ANDROID_NDK_HOME="$DEFAULT_NDK"
fi
export ANDROID_NDK_HOME
echo "▸ ndk: $ANDROID_NDK_HOME ($(ndk_version "$ANDROID_NDK_HOME"))"

echo "▸ swift: $(command -v swift) — $(swift --version 2>/dev/null | head -1)"

if [ "$DUMMY" = 0 ]; then
    echo "▸ building Swift runtime ($CONFIG, $TRIPLE)"
    touch Package.swift   # manifest declares different targets per mode; force re-evaluation
swift build -c "$CONFIG" --product SwiftUIAndroidApp \
        --swift-sdk swift-6.4.3-RELEASE_android --triple "$TRIPLE" 2>&1 \
        | grep -E "error:|warning: unre|Build complete|Compiling|Linking" | tail -8
    SO=$(find .build/out -name "libSwiftUIAndroidApp.so" -newer Package.swift 2>/dev/null | head -1)
    [ -n "$SO" ] || SO=$(find .build/out -name "libSwiftUIAndroidApp.so" | head -1)
    echo "▸ product: $SO"
    SWIFT_LIB_SO="$ROOT/$SO" ./scripts/build-apk.sh --abi "$ABI"
else
    ./scripts/build-apk.sh --dummy --abi "$ABI"
fi

if [ "$INSTALL" = 1 ]; then
    echo "▸ device test"
    ./scripts/device-test.sh build/SwiftUI-Android.apk || {
        echo "▸ device test FAILED (see evidence above)" >&2
        exit 1
    }
fi
