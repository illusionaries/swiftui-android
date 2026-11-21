#!/usr/bin/env bash
# Apple's property-wrapper macros (@State, @Binding, @Environment, …) are implemented in Apple's
# own plugin (`libSwiftUIMacros.dylib`). SwiftPM does not forward `-external-plugin-path` from a
# manifest to Android target builds, so the build scripts pass it on the command line.
#
# Usage: source scripts/port/plugin-flags.sh; swift build … "${PORT_PLUGIN_FLAGS[@]}"
: "${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN}"
PORT_MACRO_PLUGIN_DIR="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins"
PORT_MACRO_PLUGIN_SERVER="$SWIFT_TOOLCHAIN/usr/bin/swift-plugin-server"
PORT_PLUGIN_FLAGS=()
if [ -d "$PORT_MACRO_PLUGIN_DIR" ] && [ -x "$PORT_MACRO_PLUGIN_SERVER" ]; then
    PORT_PLUGIN_FLAGS=(-Xswiftc -external-plugin-path -Xswiftc "$PORT_MACRO_PLUGIN_DIR#$PORT_MACRO_PLUGIN_SERVER")
fi
