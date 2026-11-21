#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# env.sh — "where does the toolchain live on this machine?"
#
# The build needs four outside things: an OSS Swift toolchain, the Swift SDK for Android,
# the Android SDK with an NDK, and a JDK. None of their locations are the same on two
# machines, and none of them belong in a committed file, so they are discovered here:
#
#   1. an explicitly exported variable (SWIFT_TOOLCHAIN, ANDROID_HOME, …)
#   2. scripts/local.env — a gitignored file of overrides, see scripts/local.env.example
#   3. the conventional install location of the upstream tool
#
# Nothing is required at source time: a script asks for what it needs with `port_env_need`
# and gets an actionable error when that piece is missing. `scripts/env.sh --check` prints
# the whole report, which is the fastest way to see what went wrong.
#
# Exported: SWIFT_TOOLCHAIN, SWIFT_ANDROID_SDK, ANDROID_HOME, ANDROID_NDK_HOME,
#           ANDROID_NDK_ROOT, JAVA_HOME, APPLE_SDK, PORT_MACRO_PLUGIN_DIR
#           (plus the toolchain/JDK bin directories on PATH)
# Set:      PORT_ROOT, ADB, EMULATOR_BIN, AVDMANAGER, SDKMANAGER, NDK_MAJOR
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
#   port_env_need swift android java        # exits 2 with the reason when one is missing
# ────────────────────────────────────────────────────────────────────────────────

[ -n "${PORT_ENV_LOADED:-}" ] && return 0
PORT_ENV_LOADED=1

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── output ────────────────────────────────────────────────────────────────────
_port_warn() { printf 'env: %s\n' "$*" >&2; }

port_env_die() {
    printf 'env: %s\n' "$*" >&2
    printf 'env: set it in the environment or in scripts/local.env (see scripts/local.env.example);\n' >&2
    printf 'env: run scripts/env.sh --check for the full report.\n' >&2
    exit 2
}

# ── local overrides ───────────────────────────────────────────────────────────
# Not committed: it holds one person's paths. export, so child processes see them too.
if [ -f "$PORT_ROOT/scripts/local.env" ]; then
    # shellcheck disable=SC1091,SC1090
    . "$PORT_ROOT/scripts/local.env"
fi

# ── small predicates ──────────────────────────────────────────────────────────
_port_is_toolchain() { [ -n "${1:-}" ] && [ -x "$1/usr/bin/swift" ]; }
_port_is_android_home() { [ -n "${1:-}" ] && [ -d "$1/platform-tools" ] && [ -d "$1/platforms" ]; }
_port_is_swift_android_sdk() { [ -n "${1:-}" ] && [ -d "$1/ndk-sysroot" ] && [ -d "$1/swift-resources" ]; }

_port_ndk_major() {
    local props="${1:-}/source.properties"
    [ -f "$props" ] || { printf '0'; return; }
    sed -n 's/^Pkg.Revision *= *\([0-9][0-9]*\).*/\1/p' "$props" | head -n 1 | grep . || printf '0'
}

_port_java_major() {
    local home="${1:-}" line
    [ -x "$home/bin/java" ] || { printf '0'; return; }
    line="$("$home/bin/java" -version 2>&1 | head -n 1)"
    printf '%s' "$line" | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1 | grep . || printf '0'
}

# Resolve a `swift` binary to its toolchain root (…/usr/bin/swift -> …). Fails for the Xcode
# stub in /usr/bin, which is a shim rather than a toolchain layout.
_port_toolchain_of_bin() {
    local bin="${1:-}" dir
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    dir="$(cd "$(dirname "$bin")/../.." 2>/dev/null && pwd -P)" || return 1
    [ "$dir" = / ] && return 1
    _port_is_toolchain "$dir" && printf '%s' "$dir"
}

# Newest match for a glob, version-sorted (`sort -V` understands 6.4.3 < 6.5.0).
_port_newest() {
    # shellcheck disable=SC2086
    ls -d $1 2>/dev/null | sort -rV | head -n 1
}

# ── Swift toolchain (the OSS one: Xcode's Swift cannot target Android) ────────
# Accepted forms of SWIFT_TOOLCHAIN: a toolchain root, an .xctoolchain, or the `Payload`
# directory of an unpacked .pkg — all three contain usr/bin/swift.
_port_find_swift_toolchain() {
    local cand
    if _port_is_toolchain "${SWIFT_TOOLCHAIN:-}"; then
        printf '%s' "$SWIFT_TOOLCHAIN"; return 0
    fi
    if cand="$(_port_toolchain_of_bin "${SWIFT_BIN:-}")"; then
        printf '%s' "$cand"; return 0
    fi
    # A `swift` already on PATH, when it belongs to an Android-capable toolchain.
    cand="$(_port_toolchain_of_bin "$(command -v swift 2>/dev/null || true)")"
    case "${SWIFT_TOOLCHAIN_FROM_PATH:-1}" in
        1) [ -n "$cand" ] && { printf '%s' "$cand"; return 0; } ;;
    esac
    for cand in \
        "$HOME/Library/Developer/Toolchains/swift-6.4.3-RELEASE.xctoolchain" \
        "$HOME/.swiftly/toolchains/swift-6.4.3-RELEASE" \
        "$(_port_newest "$HOME/.swiftly/toolchains/*")" \
        "/Library/Developer/Toolchains/swift-6.4.3-RELEASE.xctoolchain" \
        "$(_port_newest "/Library/Developer/Toolchains/*.xctoolchain")" \
        /usr/local/swift /opt/swift; do
        _port_is_toolchain "$cand" && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# ── Swift SDK for Android (installed under an artifactbundle) ─────────────────
_port_find_swift_android_sdk() {
    local base cand
    if _port_is_swift_android_sdk "${SWIFT_ANDROID_SDK:-}"; then
        printf '%s' "$SWIFT_ANDROID_SDK"; return 0
    fi
    for base in "${SWIFT_SDKS_DIR:-}" "$HOME/Library/org.swift.swiftpm/swift-sdks" \
                "$HOME/.swiftpm/swift-sdks" "$HOME/Library/swift/swift-sdks"; do
        [ -n "$base" ] || continue
        cand="$(_port_newest "$base/*android*.artifactbundle/swift-android")"
        [ -n "$cand" ] && _port_is_swift_android_sdk "$cand" && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# ── Android SDK ───────────────────────────────────────────────────────────────
_port_find_android_home() {
    local cand
    for cand in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
                "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "$HOME/Android/sdk" \
                /usr/local/share/android-sdk /opt/android-sdk /opt/android/platform-tools/..; do
        _port_is_android_home "$cand" && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# ── NDK ───────────────────────────────────────────────────────────────────────
# The Swift SDK for Android 6.4.3 is built against NDK r30 (>= 27 required); an older NDK
# from another project on PATH is rejected rather than used and mysteriously failing later.
PORT_NDK_MIN_MAJOR="${PORT_NDK_MIN_MAJOR:-27}"
# Assigns the globals instead of echoing, so the rejected candidate survives for the error
# message (a `$( … )` call would throw that away with its subshell).
_port_resolve_ndk() {
    local cand major rejected=""
    for cand in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" \
                "${ANDROID_HOME:+$ANDROID_HOME/android-ndk-r30}" \
                "$(_port_newest "${ANDROID_HOME:-/nonexistent}/android-ndk-*")" \
                "$(_port_newest "${ANDROID_HOME:-/nonexistent}/ndk/*")"; do
        [ -n "$cand" ] && [ -d "$cand" ] || continue
        major="$(_port_ndk_major "$cand")"
        if [ "$major" -ge "$PORT_NDK_MIN_MAJOR" ]; then
            ANDROID_NDK_HOME="$cand"
            PORT_NDK_REJECTED=""
            return 0
        fi
        [ -n "$rejected" ] || rejected="$cand"
    done
    ANDROID_NDK_HOME="$rejected"
    PORT_NDK_REJECTED="$rejected"
    return 1
}

# ── JDK ───────────────────────────────────────────────────────────────────────
# The build pins JDK 21 (javac --release 11, d8, apksigner, keytool). Prefer a real 21 over
# whatever JAVA_HOME an interactive shell happens to export, then accept anything >= 17.
_port_find_java_home() {
    # One candidate per line: IFS is a newline, so a path may contain spaces.
    local cands cand major fallback=""
    cands="$(_port_newest '/opt/homebrew/opt/openjdk@21')
$(_port_newest '/usr/local/opt/openjdk@21')
$(_port_newest '/opt/homebrew/opt/openjdk')
$(_port_newest '/usr/local/opt/openjdk')
${JAVA_HOME:-}
$(_port_newest '/usr/lib/jvm/java-21-openjdk*')
$(_port_newest '/usr/lib/jvm/*')
$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
    local IFS=$'\n'
    for cand in $cands; do
        [ -n "$cand" ] && [ -x "$cand/bin/javac" ] || continue
        major="$(_port_java_major "$cand")"
        [ "$major" -ge 17 ] || continue
        if [ "$major" -eq 21 ]; then printf '%s' "$cand"; return 0; fi
        [ -n "$fallback" ] || fallback="$cand"
    done
    [ -n "$fallback" ] && { printf '%s' "$fallback"; return 0; }
    return 1
}


# ── Xcode (host only) ─────────────────────────────────────────────────────────
# The port reads Apple's *shipped declarations* (.swiftinterface) and runs their macros with
# Xcode's plugin; nothing Apple ships is redistributed. `xcode-select -p` finds a custom
# install, so no /Applications path is baked in.
_port_resolve_xcode() {
    local dev cand
    dev="$(xcode-select -p 2>/dev/null || true)"
    if [ -z "${APPLE_SDK:-}" ] && [ -n "$dev" ]; then
        APPLE_SDK="$dev/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
    fi
    [ -n "${APPLE_SDK:-}" ] && [ -d "$APPLE_SDK" ] || APPLE_SDK=""
    if [ -z "${PORT_MACRO_PLUGIN_DIR:-}" ]; then
        for cand in "$APPLE_SDK/usr/lib/swift/host/plugins" \
                    "$dev/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins" \
                    "$dev/Platforms/iPhoneSimulator.platform/Developer/usr/lib/swift/host/plugins" \
                    "$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"; do
            [ -n "$cand" ] && ls "$cand"/*.dylib >/dev/null 2>&1 || continue
            PORT_MACRO_PLUGIN_DIR="$cand"
            break
        done
    fi
    PORT_MACRO_PLUGIN_DIR="${PORT_MACRO_PLUGIN_DIR:-}"
}
_port_resolve_xcode

# ── resolve ───────────────────────────────────────────────────────────────────
SWIFT_TOOLCHAIN="$(_port_find_swift_toolchain || true)"
SWIFT_BIN_PATH=""
[ -n "$SWIFT_TOOLCHAIN" ] && SWIFT_BIN_PATH="$SWIFT_TOOLCHAIN/usr/bin/swift"

SWIFT_ANDROID_SDK="$(_port_find_swift_android_sdk || true)"
ANDROID_HOME="$(_port_find_android_home || true)"
if [ -n "$ANDROID_HOME" ]; then
    export ANDROID_HOME
    ANDROID_SDK_ROOT="$ANDROID_HOME"
    export ANDROID_SDK_ROOT
fi

PORT_NDK_REJECTED=""
NDK_OK=0
ANDROID_NDK_HOME=""
_port_resolve_ndk && NDK_OK=1
if [ "$NDK_OK" = 1 ]; then
    export ANDROID_NDK_HOME ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
    NDK_MAJOR="$(_port_ndk_major "$ANDROID_NDK_HOME")"
else
    # Do not hand a too-old NDK to SwiftPM/the Swift SDK: that fails much later and worse.
    unset ANDROID_NDK_HOME ANDROID_NDK_ROOT
    NDK_MAJOR=0
fi

JAVA_HOME="$(_port_find_java_home || true)"
if [ -n "$JAVA_HOME" ]; then
    export JAVA_HOME
    export PATH="$JAVA_HOME/bin:$PATH"
fi

if [ -n "$SWIFT_TOOLCHAIN" ]; then
    export SWIFT_TOOLCHAIN
    # Only the OSS toolchain may shadow the system `swift`: Xcode's is useless for Android.
    case "$SWIFT_BIN_PATH" in
        /usr/bin/swift|/Applications/Xcode*.app/*) ;;
        *) export PATH="$SWIFT_TOOLCHAIN/usr/bin:$PATH" ;;
    esac
fi

# Convenience handles for the Android tools (not exported: no reason to leak them).
ADB=""
EMULATOR_BIN=""
AVDMANAGER=""
SDKMANAGER=""
if [ -n "$ANDROID_HOME" ]; then
    ADB="$ANDROID_HOME/platform-tools/adb"
    EMULATOR_BIN="$ANDROID_HOME/emulator/emulator"
    AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
    SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
fi

# ── requirements ──────────────────────────────────────────────────────────────
#   swift      an OSS Swift toolchain              sdk     the Swift SDK for Android
#   android    the Android SDK                     ndk     NDK >= 27
#   java       JDK >= 17 (21 preferred)            adb     platform-tools/adb
#   xcode      Xcode's iOS SDK + macro plugin      (host-side steps only)
port_env_need() {
    local what missing=""
    for what in "$@"; do
        case "$what" in
            swift)
                [ -n "$SWIFT_TOOLCHAIN" ] || missing="${missing}swift (SWIFT_TOOLCHAIN)"
                ;;
            swift-sdk|sdk)
                [ -n "$SWIFT_ANDROID_SDK" ] || missing="${missing}swift-sdk (SWIFT_ANDROID_SDK)"
                ;;
            android)
                [ -n "$ANDROID_HOME" ] || missing="${missing}android (ANDROID_HOME)"
                ;;
            ndk)
                [ "$NDK_OK" = 1 ] || missing="${missing}ndk (ANDROID_NDK_HOME)"
                ;;
            java)
                [ -n "$JAVA_HOME" ] || missing="${missing}java (JAVA_HOME)"
                ;;
            adb)
                [ -x "$ADB" ] || missing="${missing}adb ($ANDROID_HOME/platform-tools/adb)"
                ;;
            xcode)
                { [ -n "$APPLE_SDK" ] && [ -n "$PORT_MACRO_PLUGIN_DIR" ]; } \
                    || missing="${missing}xcode (install Xcode, or set APPLE_SDK)"
                ;;
            *)
                port_env_die "unknown requirement '$what'"
                ;;
        esac
    done
    [ -z "$missing" ] && return 0

    if [ -n "${PORT_NDK_REJECTED:-}" ] && [ "$NDK_MAJOR" = 0 ]; then
        printf 'env: the NDK at %s is r%s; this Swift SDK for Android needs r%s or newer.\n' \
            "$PORT_NDK_REJECTED" "$(_port_ndk_major "$PORT_NDK_REJECTED")" "$PORT_NDK_MIN_MAJOR" >&2
    fi
    port_env_die "not found: ${missing}"
}

# ── report ────────────────────────────────────────────────────────────────────
port_env_report() {
    printf 'repo             : %s\n' "$PORT_ROOT"
    printf 'swift toolchain : %s\n' "${SWIFT_TOOLCHAIN:-<missing>}"
    [ -n "$SWIFT_BIN_PATH" ] && printf '                  %s (%s)\n' \
        "$("$SWIFT_BIN_PATH" --version 2>/dev/null | head -n 1)" "$SWIFT_BIN_PATH"
    printf 'swift sdk        : %s\n' "${SWIFT_ANDROID_SDK:-<missing>}"
    printf 'android sdk      : %s\n' "${ANDROID_HOME:-<missing>}"
    printf 'android ndk      : %s%s\n' "${ANDROID_NDK_HOME:-<missing>}" \
        "$([ -n "$ANDROID_NDK_HOME" ] && printf ' (r%s)' "$NDK_MAJOR")"
    printf 'xcode            : %s\n' "${APPLE_SDK:-<missing>}"
    printf 'macro plugin     : %s\n' "${PORT_MACRO_PLUGIN_DIR:-<missing>}"
    printf 'jdk              : %s%s\n' "${JAVA_HOME:-<missing>}" \
        "$([ -n "$JAVA_HOME" ] && printf ' (%s)' "$("$JAVA_HOME/bin/java" -version 2>&1 | head -n 1 | sed 's/.*version "//;s/".*//')")"
    printf 'adb              : %s\n' "$([ -x "$ADB" ] && printf '%s' "$ADB" || printf '<missing>')"
    printf '\nlocal overrides  : %s\n' \
        "$([ -f "$PORT_ROOT/scripts/local.env" ] && echo 'scripts/local.env (gitignored)' || echo 'none (scripts/local.env.example shows the format)')"
}

port_env_ok() {
    [ -n "$SWIFT_TOOLCHAIN" ] && [ -n "$SWIFT_ANDROID_SDK" ] && [ -n "$ANDROID_HOME" ] \
        && [ "$NDK_OK" = 1 ] && [ -n "$JAVA_HOME" ] && [ -x "$ADB" ]
}

# Executed (not sourced): print the report. Exit 1 when something required is missing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    port_env_report
    port_env_ok && exit 0
    printf '\nnot ready: export the missing values, or put them in scripts/local.env\n' >&2
    exit 1
fi
