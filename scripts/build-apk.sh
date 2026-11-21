#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# build-apk.sh — build build/SwiftUI-Android.apk from scratch, reproducibly.
#
#   scripts/build-apk.sh [--abi arm64-v8a|x86_64|all] [--demo atlas|gallery] [--dummy] [--clean] [-v]
#
# Pipeline:
#   1. native:  swift build -c release --product SwiftUIAndroidApp
#               --swift-sdk <android sdk> --triple <triple> --static-swift-stdlib
#               (or, with --dummy, an NDK-compiled stub) → build/jniLibs/<abi>/
#               plus every non-system NEEDED shared library (libc++_shared.so mandatory).
#   2. res:     aapt2 compile + aapt2 link → base APK + R.java
#   3. java:    javac --release 11 → jar → d8 → classes.dex
#   4. package: base APK + classes.dex + lib/ → zipalign -p 4 → apksigner → verify.
#
# Exit codes:
#    0  success
#    1  generic failure
#    2  toolchain / SDK / NDK not available (Swift SDK for Android, Android SDK, JDK, NDK)
#    3  the Swift package build failed (see build/tmp/swift-build.log)
#    4  mandatory native runtime library missing (libc++_shared.so)
#
# Two demos ship as two independent apps. `--demo gallery` packages the control gallery as
# dev.swiftui.android.gallery → build/SwiftUI-Gallery.apk (its own launchable icon next to the
# Atlas demo); `--demo atlas` (default) packages the Atlas app as dev.swiftui.android.
#
# Env overrides: JAVA_HOME, ANDROID_HOME, ANDROID_NDK_HOME, ANDROID_PLATFORM,
#                ANDROID_BUILD_TOOLS, SWIFT_SDK, MIN_SDK, DUMMY_SWIFT, VERBOSE,
#                SWIFT_BIN / SWIFT_TOOLCHAIN (pick the Swift compiler explicitly); every
#                toolchain path is resolved by scripts/env.sh — see scripts/local.env.example,
#                SWIFT_LIB_SO (package a prebuilt product .so instead of running SwiftPM;
#                              may contain {abi}, e.g. 'build/dev/{abi}/libswiftui_app.so'),
#                SWIFT_STATIC_STDLIB=0 (do not pass --static-swift-stdlib),
#                NO_STRIP=1, STRIP=1
# ────────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="$REPO_ROOT/build"
JNI_DIR="$BUILD_DIR/jniLibs"
GEN_DIR="$BUILD_DIR/gen"
RES_DIR="$BUILD_DIR/res"
CLASSES_DIR="$BUILD_DIR/classes"
TMP_DIR="$BUILD_DIR/tmp"
APK_OUT="$BUILD_DIR/SwiftUI-Android.apk"
KEYSTORE="$BUILD_DIR/debug.keystore"

SWIFT_SDK_ID="${SWIFT_SDK:-swift-6.4.3-RELEASE_android}"
MIN_SDK="${MIN_SDK:-28}"
TARGET_SDK="${TARGET_SDK:-35}"
PRODUCT="SwiftUIAndroidApp"
# The Java host loads exactly this name.
NATIVE_LIB_NAME="swiftui_app"

DEMO="${SWIFTUI_DEMO:-atlas}"
DUMMY="${DUMMY_SWIFT:-0}"
VERBOSE="${VERBOSE:-0}"
CLEAN=0
ABIS=()

# ── logging ────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { local code="${2:-1}"; printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit "$code"; }
run()  {
  if [ "$VERBOSE" = "1" ]; then printf '    + %s\n' "$*"; fi
  "$@"
}

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --abi <abi>   arm64-v8a (default), x86_64, or all (one APK, both ABIs)
  --demo <name> atlas (default) → build/SwiftUI-Android.apk  (dev.swiftui.android)
                gallery         → build/SwiftUI-Gallery.apk  (dev.swiftui.android.gallery)
  --dummy       skip the Swift build, package a stub libswiftui_app.so instead
                (same as DUMMY_SWIFT=1; validates APK assembly without a Swift runtime)
  --clean       remove build/ first (keeps nothing, including the debug keystore)
  -v|--verbose  echo every command
  -h|--help     this help
EOF
}

# ── argument parsing ───────────────────────────────────────────────────────────
add_abi() {
  case "$1" in
    arm64-v8a|x86_64) ABIS+=("$1") ;;
    all) ABIS+=(arm64-v8a x86_64) ;;
    *) usage >&2; die "unsupported --abi '$1' (arm64-v8a|x86_64|all)" 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --abi) [ $# -ge 2 ] || die "--abi needs a value" 1; add_abi "$2"; shift 2 ;;
    --abi=*) add_abi "${1#*=}"; shift ;;
    --demo) [ $# -ge 2 ] || die "--demo needs a value (atlas|gallery)" 1; DEMO="$2"; shift 2 ;;
    --demo=*) DEMO="${1#*=}"; shift ;;
    --dummy) DUMMY=1; shift ;;
    --clean) CLEAN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument '$1'" 1 ;;
  esac
done
[ "${#ABIS[@]}" -gt 0 ] || ABIS=(arm64-v8a)
case "${SWIFT_LIB_SO:-}" in
  *'{abi}'*) : ;;
  *)
    if [ -n "${SWIFT_LIB_SO:-}" ] && [ "${#ABIS[@]}" -gt 1 ]; then
      die "SWIFT_LIB_SO packages one prebuilt .so; use SWIFT_LIB_SO='path/{abi}/libswiftui_app.so' for --abi all" 1
    fi
    ;;
esac

# Deduplicate ABIs (bash 3.2 has no associative arrays).
_DEDUP=" "
for abi in "${ABIS[@]}"; do
  case "$_DEDUP" in
    *" $abi "*) ;;
    *) _DEDUP="$_DEDUP$abi " ;;
  esac
done
ABIS=()
for abi in $_DEDUP; do ABIS+=("$abi"); done
unset _DEDUP

# ── demo selection ────────────────────────────────────────────────────────────
# Both demos come from the same Swift library; the demo is chosen at compile time
# (Package.swift reads SWIFTUI_DEMO_GALLERY) so the two APKs are fully independent apps with
# their own application ids and launcher icons.
case "$DEMO" in
  atlas)
    APP_PACKAGE="dev.swiftui.android"
    APK_OUT="$BUILD_DIR/SwiftUI-Android.apk"
    ;;
  gallery)
    APP_PACKAGE="dev.swiftui.android.gallery"
    APK_OUT="$BUILD_DIR/SwiftUI-Gallery.apk"
    export SWIFTUI_DEMO_GALLERY=1
    ;;
  *)
    usage >&2
    die "unsupported --demo '$DEMO' (atlas|gallery)" 1
    ;;
esac

# ── ABI tables (bash 3.2 compatible: functions instead of associative arrays) ──
abi_swift_triple() {
  case "$1" in
    arm64-v8a) echo "aarch64-unknown-linux-android${MIN_SDK}" ;;
    x86_64)    echo "x86_64-unknown-linux-android${MIN_SDK}" ;;
    *) die "internal: unknown abi '$1'" 1 ;;
  esac
}
abi_ndk_triple() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android" ;;
    x86_64)    echo "x86_64-linux-android" ;;
  esac
}
abi_arch_fragment() {
  case "$1" in
    arm64-v8a) echo "aarch64" ;;
    x86_64)    echo "x86_64" ;;
  esac
}

# ── toolchain discovery ────────────────────────────────────────────────────────
# The JDK, Android SDK, NDK, Swift toolchain and Swift SDK for Android are all resolved in one
# place — scripts/env.sh — from the environment, a gitignored scripts/local.env, or the
# conventional install locations. No machine-specific path is committed.
# shellcheck source=scripts/env.sh
source "$SCRIPT_DIR/env.sh"
port_env_need java android ndk
export PATH="$JAVA_HOME/bin:$PATH"   # keytool, jarsigner and zip helpers

[ -d "$ANDROID_HOME" ] || die "ANDROID_HOME='$ANDROID_HOME' is not a directory" 2
[ -d "$ANDROID_NDK_HOME" ] || die "ANDROID_NDK_HOME='$ANDROID_NDK_HOME' is not a directory" 2

# SwiftPM and the Swift SDK for Android both read the NDK from the environment; publish the
# resolved r30 so the child processes agree with this script.
export ANDROID_NDK_HOME ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"

NDK_HOST_TAG="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* 2>/dev/null | head -n 1 || true)"
[ -n "$NDK_HOST_TAG" ] || die "NDK has no toolchains/llvm/prebuilt/* directory" 2
NDK_BIN="$NDK_HOST_TAG/bin"
NDK_SYSROOT_LIB="$NDK_HOST_TAG/sysroot/usr/lib"
LLVM_READELF="$NDK_BIN/llvm-readelf"
LLVM_STRIP="$NDK_BIN/llvm-strip"
[ -x "$LLVM_READELF" ] || die "missing llvm-readelf in NDK ($LLVM_READELF)" 2

ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-${TARGET_SDK}}"
ANDROID_JAR="$ANDROID_HOME/platforms/$ANDROID_PLATFORM/android.jar"
[ -f "$ANDROID_JAR" ] || die "android.jar not found at $ANDROID_JAR (need platform $ANDROID_PLATFORM)" 2

if [ -n "${ANDROID_BUILD_TOOLS:-}" ]; then
  BUILD_TOOLS="$ANDROID_BUILD_TOOLS"
else
  BUILD_TOOLS="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
fi
[ -n "${BUILD_TOOLS:-}" ] && [ -d "$BUILD_TOOLS" ] || die "Android build-tools not found under $ANDROID_HOME/build-tools" 2

AAPT2="$BUILD_TOOLS/aapt2"
D8="$BUILD_TOOLS/d8"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
for tool in "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER"; do
  [ -x "$tool" ] || die "missing build-tools binary: $tool" 2
done
command -v zip >/dev/null 2>&1 || die "the 'zip' command is required" 2
command -v unzip >/dev/null 2>&1 || die "the 'unzip' command is required" 2
command -v keytool >/dev/null 2>&1 || die "keytool not found (JAVA_HOME/bin)" 2

# The Swift compiler comes from scripts/env.sh too (SWIFT_BIN / SWIFT_TOOLCHAIN override the
# discovery). SwiftPM's --swift-sdk resolves the SDK by id, so only the id is needed here; the
# directories are for a second, independent lookup when a runtime library has to be bundled.
SWIFT_SDKS_DIRS=()
[ -n "${SWIFT_SDKS_DIR:-}" ] && SWIFT_SDKS_DIRS+=("$SWIFT_SDKS_DIR")
[ -n "${SWIFT_ANDROID_SDK:-}" ] && SWIFT_SDKS_DIRS+=("$(dirname "$(dirname "$SWIFT_ANDROID_SDK")")")

if [ "$DUMMY" != "1" ] && [ -z "${SWIFT_LIB_SO:-}" ]; then
  port_env_need swift sdk
  SWIFT="$SWIFT_BIN_PATH"
  SWIFT_VERSION="$("$SWIFT" --version 2>&1 | head -n 1)"
  if ! "$SWIFT" sdk list 2>/dev/null | grep -q "$SWIFT_SDK_ID"; then
    die "Swift SDK '$SWIFT_SDK_ID' is not installed (try: swift sdk install <url>)" 2
  fi
  case "$SWIFT_VERSION" in
    *6.4.3*) : ;;
    *)
      warn "the Swift compiler is '$SWIFT_VERSION' but the Android SDK was built with 6.4.3;"
      warn "building anyway, but a compiler/SDK mismatch fails inside Foundation."
      warn "fix with: SWIFT_TOOLCHAIN=/Library/Developer/Toolchains/swift-6.4.3-RELEASE.xctoolchain $0 ..."
      ;;
  esac
fi

log "Android SDK   : $ANDROID_HOME"
info "platform    : $ANDROID_PLATFORM ($ANDROID_JAR)"
info "build-tools : $BUILD_TOOLS"
info "NDK         : $ANDROID_NDK_HOME ($(basename "$NDK_HOST_TAG"))"
info "JDK         : $JAVA_HOME ($("$JAVA_HOME/bin/javac" -version 2>&1 | head -n 1))"
info "ABIs        : ${ABIS[*]}"
info "demo        : $DEMO ($APP_PACKAGE)"
info "mode        : $([ "$DUMMY" = "1" ] && echo 'dummy native stub (no Swift build)' || echo 'SwiftPM release build')"
if [ "$DUMMY" != "1" ]; then
  if [ -n "${SWIFT_LIB_SO:-}" ]; then
    info "native src  : prebuilt $SWIFT_LIB_SO"
  else
    info "swift       : $SWIFT ($SWIFT_VERSION)"
    info "swift sdk   : $SWIFT_SDK_ID"
  fi
fi

# ── clean ──────────────────────────────────────────────────────────────────────
if [ "$CLEAN" = "1" ]; then
  log "cleaning $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR" "$JNI_DIR" "$GEN_DIR" "$RES_DIR" "$CLASSES_DIR" "$TMP_DIR"

# ── cross-process lock ────────────────────────────────────────────────────────
# Several agents/terminals can run this script (or device-test.sh) against the same tree; two
# concurrent runs delete each other's build/tmp and make `zip` fail halfway through packaging.
LOCK_DIR="${TMPDIR:-/tmp}/swiftui-android-build-apk-$(printf '%s' "$REPO_ROOT" | shasum | cut -c1-12).lock"
acquire_build_lock() {
  local holder waited=0
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    log "another build-apk.sh is running (pid $holder); waiting for it to finish"
    while [ -d "$LOCK_DIR" ] && kill -0 "$holder" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
      [ "$waited" -gt 600 ] && die "timed out waiting for $LOCK_DIR (pid $holder)" 1
    done
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || die "could not acquire $LOCK_DIR" 1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  # Stale lock from a killed run.
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || die "could not acquire $LOCK_DIR" 1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}
release_build_lock() { rm -rf "$LOCK_DIR"; }
acquire_build_lock
trap release_build_lock EXIT
trap 'release_build_lock; exit 130' INT
trap 'release_build_lock; exit 143' TERM

rm -rf "${JNI_DIR:?}"/* "$GEN_DIR"/* "$RES_DIR"/* "$CLASSES_DIR"/* "$TMP_DIR"/*
mkdir -p "$TMP_DIR/stage" "$TMP_DIR/dex"

# ──────────────────────────────────────────────────────────────────────────────
# 1. Native library + its runtime dependencies
# ──────────────────────────────────────────────────────────────────────────────
# System libraries provided by the platform: never packaged into the APK.
is_system_lib() {
  case "$1" in
    libc.so|libm.so|libdl.so|liblog.so|libz.so|libandroid.so|libjnigraphics.so|ld-android.so|\
libGLESv1_CM.so|libGLESv2.so|libGLESv3.so|libEGL.so|libOpenSLES.so|libOpenMAXAL.so|libvulkan.so|\
libnativewindow.so|libsync.so|libstdc++.so|libhwui.so|libui.so|libbinder.so|libcutils.so|\
libbase.so|libutils.so|libc++.so)
      return 0 ;;
  esac
  return 1
}

# find_runtime_lib <soname> <abi> → absolute path or empty
find_runtime_lib() {
  local name="$1" abi="$2" arch ndk_triple found
  arch="$(abi_arch_fragment "$abi")"
  ndk_triple="$(abi_ndk_triple "$abi")"

  # NDK sysroot (libc++_shared.so lives here): prefer the arch-specific dir, then the API dir.
  for candidate in \
    "$NDK_SYSROOT_LIB/$ndk_triple/$name" \
    "$NDK_SYSROOT_LIB/$ndk_triple/${MIN_SDK}/$name" \
    "$NDK_SYSROOT_LIB/$name"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  found="$(find "$NDK_SYSROOT_LIB" -name "$name" -path "*$ndk_triple*" 2>/dev/null | head -n 1 || true)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi

  # Swift SDK for Android runtime libraries (libswiftCore.so, libdispatch.so, ...).
  # Layout: <sdk>.artifactbundle/swift-android/swift-resources/usr/lib/swift-<arch>/android/
  local sdk_dir
  for sdk_dir in ${SWIFT_SDKS_DIRS[@]+"${SWIFT_SDKS_DIRS[@]}"}; do
    [ -d "$sdk_dir" ] || continue
    found="$(find "$sdk_dir" -name "$name" -path "*$arch*" 2>/dev/null | head -n 1 || true)"
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
  done
  return 0
}

# Collect non-system NEEDED sonames from an ELF shared object.
needed_libs() {
  "$LLVM_READELF" -d "$1" 2>/dev/null \
    | awk '/\(NEEDED\)/ { gsub(/\[|\]/, "", $NF); print $NF }' \
    | sort -u
}

collect_native_libs() {
  local abi="$1" dest="$JNI_DIR/$abi"
  mkdir -p "$dest"

  if [ "$DUMMY" = "1" ]; then
    local clang
    clang="$NDK_BIN/$( [ "$abi" = "arm64-v8a" ] && echo aarch64 || echo x86_64 )-linux-android${MIN_SDK}-clang"
    [ -x "$clang" ] || die "missing NDK clang: $clang" 2
    log "native: compiling dummy stub for $abi"
    run "$clang" -shared -fPIC -O2 -Wall -Wextra \
      -o "$dest/lib${NATIVE_LIB_NAME}.so" "$REPO_ROOT/app/native/dummy_swift.c"
  elif [ -n "${SWIFT_LIB_SO:-}" ]; then
    # Package a product .so built outside this script (CI cache, dev stand-in runtime, ...).
    # `{abi}` in the path is substituted per architecture.
    local prebuilt="${SWIFT_LIB_SO//\{abi\}/$abi}"
    log "native: using prebuilt $prebuilt for $abi"
    [ -f "$prebuilt" ] || die "SWIFT_LIB_SO='$prebuilt' does not exist" 1
    cp -f "$prebuilt" "$dest/lib${NATIVE_LIB_NAME}.so"
  else
    local triple bin_path src log_file
    triple="$(abi_swift_triple "$abi")"
    log_file="$TMP_DIR/swift-build-${abi}.log"
    log "native: swift build --product $PRODUCT ($triple)"
    local -a swift_build_args
    swift_build_args=(
      build -c release
      --package-path "$REPO_ROOT"
      --product "$PRODUCT"
      --swift-sdk "$SWIFT_SDK_ID"
      --triple "$triple"
    )
    if [ "${SWIFT_STATIC_STDLIB:-1}" = "1" ]; then
      swift_build_args+=(--static-swift-stdlib)
    fi
    if ! run "$SWIFT" "${swift_build_args[@]}" >"$log_file" 2>&1; then
      printf '\n' >&2
      tail -n 30 "$log_file" >&2 || true
      die "swift build failed for $abi — full log: ${log_file#$REPO_ROOT/}
       check the toolchain/SDK match (need Swift 6.4.3 OSS + $SWIFT_SDK_ID);
       SWIFT_STATIC_STDLIB=0 skips --static-swift-stdlib" 3
    fi
    if [ "$VERBOSE" = "1" ]; then cat "$log_file"; fi
    bin_path="$("$SWIFT" build -c release --package-path "$REPO_ROOT" --show-bin-path \
      --swift-sdk "$SWIFT_SDK_ID" --triple "$triple" 2>/dev/null | tail -n 1)"
    src="$bin_path/lib${PRODUCT}.so"
    if [ ! -f "$src" ]; then
      # Fall back to the conventional cross-build directory layout.
      src="$(ls -1 "$REPO_ROOT/.build/$triple/release/lib${PRODUCT}.so" \
                "$REPO_ROOT/.build/release/lib${PRODUCT}.so" 2>/dev/null | head -n 1 || true)"
    fi
    [ -f "$src" ] || die "SwiftPM did not produce lib${PRODUCT}.so (looked in '${bin_path:-?}')"
    info "built $(basename "$src") ($(du -h "$src" | cut -f1))"
    cp -f "$src" "$dest/lib${NATIVE_LIB_NAME}.so"
    if [ "${STRIP:-0}" = "1" ] && [ -x "$LLVM_STRIP" ]; then
      "$LLVM_STRIP" --strip-all "$dest/lib${NATIVE_LIB_NAME}.so"
    fi
  fi

  # libc++_shared.so is mandatory: the Swift runtime is built against the NDK's libc++.
  local libcxx
  libcxx="$(find_runtime_lib libc++_shared.so "$abi")"
  if [ -z "$libcxx" ]; then
    die "libc++_shared.so not found in the NDK sysroot for $abi ($NDK_SYSROOT_LIB)" 4
  fi
  cp -f "$libcxx" "$dest/libc++_shared.so"
  # The NDK ships libc++_shared.so with debug info (~9 MB); AGP strips bundled native libs
  # too. Stripping is safe and brings it down to ~1 MB.
  if [ "${NO_STRIP:-0}" != "1" ] && [ -x "$LLVM_STRIP" ]; then
    "$LLVM_STRIP" --strip-unneeded "$dest/libc++_shared.so" 2>/dev/null || true
  fi

  # Pull in every non-system dependency we can resolve — transitively, because e.g.
  # libFoundation.so itself NEEDs libFoundationEssentials.so and lib_FoundationICU.so.
  # (With --static-swift-stdlib the product usually only NEEDs libc++_shared.so.)
  # String lists are used instead of arrays: bash 3.2 (macOS /bin/bash) errors on
  # "${#array[@]}" for an empty array under `set -u`.
  local queue scanned current lib path missing
  queue="$dest/lib${NATIVE_LIB_NAME}.so"
  scanned="|"
  missing=""
  while [ -n "$queue" ]; do
    current="${queue%%$'\n'*}"
    if [ "$current" = "$queue" ]; then
      queue=""
    else
      queue="${queue#*$'\n'}"
    fi
    case "$scanned" in
      *"|$current|"*) continue ;;
    esac
    scanned="$scanned$current|"
    while IFS= read -r lib; do
      [ -n "$lib" ] || continue
      [ "$lib" = "libc++_shared.so" ] && continue
      is_system_lib "$lib" && continue
      if [ -f "$dest/$lib" ]; then
        queue="${queue:+$queue$'\n'}$dest/$lib"
        continue
      fi
      path="$(find_runtime_lib "$lib" "$abi")"
      if [ -z "$path" ]; then
        missing="${missing:+$missing }$lib"
        continue
      fi
      info "bundling $lib <- ${path#$ANDROID_HOME/}"
      cp -f "$path" "$dest/$lib"
      if [ "${NO_STRIP:-0}" != "1" ] && [ -x "$LLVM_STRIP" ]; then
        "$LLVM_STRIP" --strip-all "$dest/$lib" 2>/dev/null || true
      fi
      queue="${queue:+$queue$'\n'}$dest/$lib"
    done < <(needed_libs "$current")
  done

  if [ -n "$missing" ]; then
    warn "unresolved NEEDED libraries for $abi (APK may fail to load): $missing"
  fi
}

for abi in "${ABIS[@]}"; do
  collect_native_libs "$abi"
done

# ──────────────────────────────────────────────────────────────────────────────
# 2. Resources → base APK + R.java
# ──────────────────────────────────────────────────────────────────────────────
log "resources: aapt2 compile/link"
run "$AAPT2" compile --dir "$REPO_ROOT/app/res" -o "$RES_DIR/resources.zip"

# One manifest, one package id per demo: the gallery variant differs only in the package name,
# the (fully-qualified) activity class and the app label. The Java sources reference
# `R` from their own package, so keep R.java there with --custom-package.
MANIFEST="$REPO_ROOT/app/AndroidManifest.xml"
EXTRA_LINK_ARGS=""
if [ "$DEMO" = "gallery" ]; then
  MANIFEST="$TMP_DIR/AndroidManifest.gallery.xml"
  log "resources: gallery manifest ($APP_PACKAGE)"
  sed -e 's/package="dev\.swiftui\.android"/package="dev.swiftui.android.gallery"/' \
      -e 's/android:name="\.MainActivity"/android:name="dev.swiftui.android.MainActivity"/' \
      -e 's/@string\/app_name/@string\/app_name_gallery/g' \
      "$REPO_ROOT/app/AndroidManifest.xml" > "$MANIFEST"
  grep -q "package=\"$APP_PACKAGE\"" "$MANIFEST" \
    || die "could not rewrite the manifest package to $APP_PACKAGE"
  grep -q 'android:name="dev.swiftui.android.MainActivity"' "$MANIFEST" \
    || die "could not fully qualify the activity name in the gallery manifest"
  EXTRA_LINK_ARGS="--custom-package dev.swiftui.android"
fi

# shellcheck disable=SC2086  # EXTRA_LINK_ARGS is an intentional (possibly empty) word list
run "$AAPT2" link \
  -o "$TMP_DIR/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$MANIFEST" \
  --java "$GEN_DIR" \
  --min-sdk-version "$MIN_SDK" \
  --target-sdk-version "$TARGET_SDK" \
  --auto-add-overlay \
  $EXTRA_LINK_ARGS \
  "$RES_DIR/resources.zip"
[ -f "$GEN_DIR/dev/swiftui/android/R.java" ] \
  || die "aapt2 link did not generate dev/swiftui/android/R.java"
[ -f "$TMP_DIR/base.apk" ] || die "aapt2 link did not produce a base APK"

# ──────────────────────────────────────────────────────────────────────────────
# 3. Java → dex
# ──────────────────────────────────────────────────────────────────────────────
log "java: javac + d8"
find "$REPO_ROOT/app/src" -name '*.java' > "$TMP_DIR/sources.txt"
echo "$GEN_DIR/dev/swiftui/android/R.java" >> "$TMP_DIR/sources.txt"
run "$JAVA_HOME/bin/javac" \
  --release 11 \
  -classpath "$ANDROID_JAR" \
  -d "$CLASSES_DIR" \
  @"$TMP_DIR/sources.txt"
run "$JAVA_HOME/bin/jar" cf "$TMP_DIR/classes.jar" -C "$CLASSES_DIR" .
# d8 (8.2.2 in build-tools 34) throws an internal NullPointerException on any class that captures
# its enclosing instance — i.e. an anonymous inner class or a non-static nested class. Javac
# compiles those with a synthetic `this$0` field, and the failure surfaces as
# "Cannot invoke String.length() because <parameter1> is null" pointing at SomeOuter$1.class.
# Declaring listeners as `static` nested classes that take the host explicitly avoids it.
if ! run "$D8" --min-api "$MIN_SDK" --lib "$ANDROID_JAR" --output "$TMP_DIR/dex" "$TMP_DIR/classes.jar"; then
  die "d8 failed to dex the Java classes (see the error above).
       If it reports a NullPointerException about 'String.length()', it is the d8 inner-class bug:
       declare the offending listener as a static nested class instead of an anonymous/non-static one."
fi
[ -f "$TMP_DIR/dex/classes.dex" ] || die "d8 did not produce classes.dex"

# ──────────────────────────────────────────────────────────────────────────────
# 4. Assemble → align → sign → verify
# ──────────────────────────────────────────────────────────────────────────────
log "package: assembling APK"
cp -f "$TMP_DIR/base.apk" "$TMP_DIR/unsigned.apk"
cp -f "$TMP_DIR/dex/classes.dex" "$TMP_DIR/stage/classes.dex"
for abi in "${ABIS[@]}"; do
  mkdir -p "$TMP_DIR/stage/lib/$abi"
  cp -f "$JNI_DIR/$abi"/*.so "$TMP_DIR/stage/lib/$abi/"
done
( cd "$TMP_DIR/stage" && run zip -q -r -X "$TMP_DIR/unsigned.apk" classes.dex lib )

log "package: zipalign -p 4"
run "$ZIPALIGN" -f -p 4 "$TMP_DIR/unsigned.apk" "$TMP_DIR/aligned.apk"

if [ ! -f "$KEYSTORE" ]; then
  log "package: creating debug keystore $KEYSTORE"
  run keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -storepass android -keypass android \
    -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
else
  info "reusing keystore $KEYSTORE"
fi

log "package: apksigner sign"
rm -f "$APK_OUT"
run "$APKSIGNER" sign \
  --ks "$KEYSTORE" \
  --ks-key-alias androiddebugkey \
  --ks-pass pass:android \
  --key-pass pass:android \
  --min-sdk-version "$MIN_SDK" \
  --out "$APK_OUT" \
  "$TMP_DIR/aligned.apk"

# ── self checks ────────────────────────────────────────────────────────────────
log "verify"
run "$APKSIGNER" verify --print-certs "$APK_OUT"

LISTING="$(unzip -l "$APK_OUT")"
missing=0
for required in AndroidManifest.xml classes.dex resources.arsc; do
  if ! printf '%s\n' "$LISTING" | grep -q " $required\$"; then
    warn "APK is missing $required"
    missing=1
  fi
done
for abi in "${ABIS[@]}"; do
  for lib in "lib/$abi/lib${NATIVE_LIB_NAME}.so" "lib/$abi/libc++_shared.so"; do
    if ! printf '%s\n' "$LISTING" | grep -q " $lib\$"; then
      warn "APK is missing $lib"
      missing=1
    fi
  done
done
[ "$missing" = "0" ] || die "APK contents check failed"

# ── summary ────────────────────────────────────────────────────────────────────
SIZE_BYTES="$(wc -c < "$APK_OUT" | tr -d ' ')"
SIZE_HUMAN="$(du -h "$APK_OUT" | cut -f1)"
BADGING="$("$AAPT2" dump badging "$APK_OUT" 2>/dev/null || true)"

printf '\n\033[1;32m✓ APK built\033[0m\n'
printf '  path   : %s\n' "${APK_OUT#$REPO_ROOT/}"
printf '  size   : %s (%s bytes)\n' "$SIZE_HUMAN" "$SIZE_BYTES"
printf '  abis   : %s\n' "${ABIS[*]}"
printf '  demo   : %s (%s)\n' "$DEMO" "$APP_PACKAGE"
printf '  mode   : %s\n' "$([ "$DUMMY" = "1" ] && echo 'dummy native stub — packaging validation only' || echo 'release Swift build')"
printf '  sha256 : %s\n' "$(shasum -a 256 "$APK_OUT" | awk '{print $1}')"

printf '\n── aapt2 dump badging ───────────────────────────────────────────\n'
printf '%s\n' "$BADGING" | grep -E '^(package|sdkVersion|targetSdkVersion|application-label|application-icon|launchable-activity|native-code|uses-permission|supports-screens|densities)' \
  || printf '%s\n' "$BADGING"

printf '\n── APK contents ─────────────────────────────────────────────────\n'
printf '%s\n' "$LISTING"
