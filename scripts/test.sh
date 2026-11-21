#!/usr/bin/env bash
#
# test.sh — run the engine's unit tests on the host.
#
# The default build is the *ported* one: it includes Apple's declarations and the Android-only
# platform shims, which shadow macOS modules of the same name (UniformTypeIdentifiers, Combine, …)
# and cannot link on the host. The engine itself is platform-independent, so the host suite builds
# the module set without the ported half.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
: "${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN}"
export PATH="$SWIFT_TOOLCHAIN/usr/bin:$PATH"
export SWIFTUI_PORT_GENERATED=0
touch Package.swift   # the manifest declares different targets per mode; force re-evaluation
swift test "$@"
