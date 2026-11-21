#!/usr/bin/env bash
# Type-check a real SwiftUI app file against the Port SDK (Apple's retargeted interface) for
# aarch64 Android. This is the proof that the demo is genuine SwiftUI source, not a lookalike.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT="$ROOT/build/port-sdk"
: "${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN}"
export PATH="$SWIFT_TOOLCHAIN/usr/bin:$PATH"
SDK="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.4.3-RELEASE_android.artifactbundle/swift-android"
PLUGIN_HOST="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins"
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
