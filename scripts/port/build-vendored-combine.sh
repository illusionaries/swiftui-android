#!/usr/bin/env bash
#
# build-vendored-combine.sh — build OpenCombine as a real `Combine` module for Android.
#
# SwiftUI's declarations are written against Combine: `ObservableObject`, `@Published`,
# `PassthroughSubject`, publishers. Android has no Combine, so the port vendors OpenCombine
# (MIT, github.com/OpenCombine/OpenCombine) at a pinned commit, compiles it for
# aarch64-android under the module name `Combine`, and supplies its small C helper layer with a
# pthread-based implementation. That makes `@StateObject` / `@ObservedObject` behave for real
# instead of trapping.
#
# Output: build/port-sdk/shims/Combine.swiftmodule (binary) + build/port-sdk/shim-objects/Combine.o
#         and COpenCombineHelpers.o
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Toolchain, Swift SDK for Android and NDK come from scripts/env.sh (environment ->
# scripts/local.env -> conventional install locations); no machine-specific path is committed.
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
port_env_need swift sdk ndk
SDK="$SWIFT_ANDROID_SDK"
TRIPLE="${TARGET_TRIPLE:-aarch64-unknown-linux-android}"
NDK_HOST_TAG="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* 2>/dev/null | head -n 1 || true)"
OPENCOMBINE_REPO="https://github.com/OpenCombine/OpenCombine.git"
OPENCOMBINE_COMMIT="1c6f02c7ed8140c0ba7a783aaddb6e0685a0037b"

OUT="$ROOT/build/port-sdk"
VENDOR="$ROOT/build/vendor"
SRC="$VENDOR/combine-src"

mkdir -p "$VENDOR" "$OUT/shim-objects" "$OUT/shims/Combine.swiftmodule"

if [ ! -d "$VENDOR/OpenCombine/.git" ]; then
    echo "→ cloning OpenCombine"
    git clone --quiet "$OPENCOMBINE_REPO" "$VENDOR/OpenCombine"
fi
git -C "$VENDOR/OpenCombine" fetch --quiet --depth 1 origin "$OPENCOMBINE_COMMIT" 2>/dev/null || true
git -C "$VENDOR/OpenCombine" checkout --quiet "$OPENCOMBINE_COMMIT"

rm -rf "$SRC" && mkdir -p "$SRC"
cp -R "$VENDOR/OpenCombine/Sources/OpenCombine/." "$SRC/"

# The library qualifies itself as `OpenCombine.`; compiled as module `Combine`, those qualifiers
# must be rewritten. That is the only source change.
python3 - "$SRC" <<'PY'
import glob, re, sys
root = sys.argv[1]
for path in glob.glob(root + "/**/*.swift", recursive=True):
    text = open(path).read()
    updated = re.sub(r"\bOpenCombine\.", "Combine.", text)
    if updated != text:
        open(path, "w").write(updated)
PY

CC="$NDK_HOST_TAG/bin/aarch64-linux-android28-clang"
echo "→ compiling C helper layer"
"$CC" -c "$ROOT/Sources/COpenCombineHelpers/COpenCombineHelpers.c" \
    -I "$ROOT/Sources/COpenCombineHelpers/include" \
    -o "$OUT/shim-objects/COpenCombineHelpers.o" \
    -std=gnu11 -O2 -fPIC -Wall

echo "→ compiling OpenCombine as module Combine"
FILES=$(find "$SRC" -name "*.swift" | tr '\n' ' ')
# shellcheck disable=SC2086
swiftc -c $FILES -module-name Combine -target "$TRIPLE" \
    -resource-dir "$SDK/swift-resources/usr/lib/swift-aarch64" -sdk "$SDK/ndk-sysroot" \
    -swift-version 5 -parse-as-library -whole-module-optimization \
    -I "$ROOT/Sources/COpenCombineHelpers/cmodule" \
    -emit-module-path "$OUT/shims/Combine.swiftmodule/aarch64-unknown-linux-android.swiftmodule" \
    -o "$OUT/shim-objects/Combine.o"

echo "  ✓ Combine (OpenCombine @ ${OPENCOMBINE_COMMIT:0:8})"
