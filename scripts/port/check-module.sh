#!/usr/bin/env bash
#
# check-module.sh — quick single-module probe used while building the Port SDK.
#
# Compiles a one-line `import <Module>` for aarch64-unknown-linux-android28 against
# build/port-sdk/{gen,shims}. Localizes errors to the module that emits them, which
# is much faster than reading the full probe log.
#
# Usage: scripts/port/check-module.sh <Module> [dir-to-import-extra...]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$ROOT/build/port-sdk"

: "${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN}"
: "${SWIFT_ANDROID_SDK:=$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.4.3-RELEASE_android.artifactbundle/swift-android}"
: "${TARGET_TRIPLE:=aarch64-unknown-linux-android28}"
export PATH="$SWIFT_TOOLCHAIN/usr/bin:$PATH"

resource_dir="$SWIFT_ANDROID_SDK/swift-resources/usr/lib/swift-aarch64"
ndk_sysroot="$SWIFT_ANDROID_SDK/ndk-sysroot"

module="${1:?usage: check-module.sh <Module>}"
tmp="$out/.check-$module.swift"
printf 'import %s\n' "$module" > "$tmp"

swiftc -typecheck "$tmp" -module-name "Check$module" -target "$TARGET_TRIPLE" \
    -resource-dir "$resource_dir" -sdk "$ndk_sysroot" -I "$out/gen" -I "$out/shims" \
    -module-cache-path "$out/.module-cache-check" \
    -enable-experimental-feature AnyAppleOSAvailability -swift-version 5 2>&1 \
  | grep -E "error:" | sed -E "s@$ROOT/build/port-sdk/(gen|shims)/([A-Za-z]+)\\.swiftmodule/[^:]+:@\\2:@"
