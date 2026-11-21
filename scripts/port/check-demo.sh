#!/usr/bin/env bash
# Type-check a real SwiftUI app file against the Port SDK (Apple's retargeted interface) for
# aarch64 Android. This is the proof that the demo is genuine SwiftUI source, not a lookalike.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT="$ROOT/build/port-sdk"
# Toolchain, Swift SDK for Android and Xcode's macro plugin come from scripts/env.sh.
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
port_env_need swift sdk xcode
SDK="$SWIFT_ANDROID_SDK"
PLUGIN_HOST="$PORT_MACRO_PLUGIN_DIR"
FILES=("$@")
[ ${#FILES[@]} -eq 0 ] && FILES=("$ROOT/demos/AtlasSwiftUI.swift")
swiftc -typecheck "${FILES[@]}" -module-name AtlasDemo \
    -target aarch64-unknown-linux-android28 \
    -resource-dir "$SDK/swift-resources/usr/lib/swift-aarch64" -sdk "$SDK/ndk-sysroot" \
    -I "$PORT/gen" -I "$PORT/shims" \
    -swift-version 5 -enable-experimental-feature AnyAppleOSAvailability \
    -external-plugin-path "$PLUGIN_HOST#$SWIFT_TOOLCHAIN/usr/bin/swift-plugin-server" \
    -module-cache-path "$PORT/.module-cache-demo"
echo "demo typecheck: OK ($(basename "${FILES[0]}"))"
