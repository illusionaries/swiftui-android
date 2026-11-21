#!/usr/bin/env bash
# Inner loop for the ported (Apple declarations + adapters) build:
# build → package → install → launch → report the first unimplemented entry point.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
# Toolchain, NDK and adb come from scripts/env.sh (environment -> scripts/local.env ->
# conventional install locations); no machine-specific path is hard-coded here.
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
port_env_need swift ndk adb

touch Package.swift   # manifest declares different targets per mode; force re-evaluation
# shellcheck source=scripts/port/plugin-flags.sh
source "$ROOT/scripts/port/plugin-flags.sh"
SWIFTUI_PORT_GENERATED=1 swift build "${PORT_PLUGIN_FLAGS[@]}" -c release --product SwiftUIAndroidApp \
    --swift-sdk swift-6.4.3-RELEASE_android --triple aarch64-unknown-linux-android28 2>&1 \
    | grep -E "error:|Build complete" | tail -3
SO=$(find .build/out -name "libSwiftUIAndroidApp.so" | head -1)
SWIFT_LIB_SO="$ROOT/$SO" ./scripts/build-apk.sh --abi arm64-v8a >/dev/null
"$ADB" uninstall dev.swiftui.android >/dev/null 2>&1 || true
"$ADB" install -r -t build/SwiftUI-Android.apk >/dev/null
"$ADB" logcat -b all -c
"$ADB" shell am start -W -n dev.swiftui.android/.MainActivity >/dev/null 2>&1 || true
sleep 3
PID=$("$ADB" shell pidof dev.swiftui.android || true)
if [ -n "$PID" ]; then
    echo "running (pid $PID)"
    "$ADB" exec-out screencap -p > build/screenshots/ported.png
else
    echo "crashed:"
    "$ADB" logcat -d | grep -E "unimplemented entry point|cannot locate symbol|Fatal signal|FATAL EXCEPTION" | head -3
fi
