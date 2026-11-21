/*
 * dev_stub_runtime.c — DEVELOPER SCAFFOLD, not part of the shipping app.
 *
 * scripts/build-apk.sh never compiles this file. It exists so the native bridge
 * (Sources/AndroidBridge/AndroidBridge.c), the Java host and the whole APK can be exercised on
 * a device/emulator *before* the Swift runtime is buildable: it implements the
 * swiftui_android_* functions from AndroidBridge.h with plain C and draws a test frame through
 * the very same ab_* drawing primitives the SwiftUI renderer will use.
 *
 * Build and package a scratch APK that actually renders:
 *
 *   NDK=$ANDROID_HOME/android-ndk-r30
 *   CC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android28-clang
 *   mkdir -p build/dev
 *   "$CC" -shared -fPIC -O2 -std=gnu11 -Wall -Wextra \
 *       -ISources/AndroidBridge/include -I"$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include" \
 *       -o build/dev/libswiftui_app.so \
 *       Sources/AndroidBridge/AndroidBridge.c app/native/dev_stub_runtime.c
 *   SWIFT_LIB_SO=$PWD/build/dev/libswiftui_app.so scripts/build-apk.sh --abi arm64-v8a
 *
 * Replace it with the Swift implementation (Sources/SwiftUIAndroid) as soon as it builds.
 */
#include "AndroidBridge.h"

#include <stdio.h>
#include <string.h>

static float g_width_dp;
static float g_height_dp;
static float g_density = 1.0f;
static float g_safe_top;
static float g_safe_bottom;

void swiftui_android_start(ABRuntime *rt) { (void)rt; }

void swiftui_android_resize(ABRuntime *rt, float width_dp, float height_dp, float density,
                            float safe_top, float safe_bottom, float safe_left, float safe_right) {
    (void)rt;
    (void)safe_left;
    (void)safe_right;
    g_width_dp = width_dp;
    g_height_dp = height_dp;
    g_density = density;
    g_safe_top = safe_top;
    g_safe_bottom = safe_bottom;
}

void swiftui_android_render(ABRuntime *rt, ABCanvas *c, float width_dp, float height_dp,
                            float density) {
    (void)density;
    bool dark = ab_is_dark_mode(rt);
    uint32_t bg = dark ? 0xFF101014u : 0xFFF6F6F8u;
    uint32_t card = dark ? 0xFF1E1E24u : 0xFFFFFFFFu;
    uint32_t title = dark ? 0xFFFFFFFFu : 0xFF111114u;
    uint32_t secondary = dark ? 0xFF9A9AA5u : 0xFF6B6B75u;
    uint32_t accent = 0xFF3A7BD5u;

    /* Background + safe-area markers (proves resize/insets arrive). */
    ab_fill_rect(c, 0, 0, width_dp, height_dp, bg);

    float top = 24.0f + g_safe_top;
    float left = 20.0f;
    float right = width_dp - 20.0f;

    /* Card with a soft shadow, a stroke and a corner radius. */
    ab_draw_shadow_round_rect(c, left, top, right, top + 140.0f, 18.0f, 0.0f, 6.0f, 16.0f,
                              0x40000000u);
    ab_fill_round_rect(c, left, top, right, top + 140.0f, 18.0f, card);
    ab_stroke_round_rect(c, left, top, right, top + 140.0f, 18.0f, 1.0f,
                         dark ? 0xFF2C2C34u : 0xFFE2E2E8u);

    /* Gradient bar. */
    const uint32_t colors[2] = {accent, 0xFF8E44ADu};
    const float stops[2] = {0.0f, 1.0f};
    ab_fill_linear_gradient_round_rect(c, left + 16.0f, top + 16.0f, right - 16.0f, top + 28.0f,
                                       6.0f, left + 16.0f, top, right - 16.0f, top, colors, stops,
                                       2);

    /* Text: title, body, and a measured label. */
    ab_draw_text(c, "SwiftUI for Android", 19, left + 16.0f, top + 66.0f, 22.0f, 700, 0, title, 0);
    ab_draw_text(c, "native Skia canvas over JNI", 28, left + 16.0f, top + 94.0f, 14.0f, 400, 0,
                 secondary, 0);

    float ascent, descent, leading;
    ab_font_metrics(c, 13.0f, 400, 0, &ascent, &descent, &leading);
    char info[96];
    snprintf(info, sizeof info, "%.0fx%.0f dp  %.2fx  asc %.1f", width_dp, height_dp, g_density,
             ascent);
    ab_draw_text(c, info, (int32_t)strlen(info), left + 16.0f, top + 122.0f, 13.0f, 400, 0,
                 secondary, 0.2f);

    /* A path (rounded triangle) + a stroked line, to cover the path command stream. */
    const float tri[] = {
        0, 40.0f, 240.0f, 1, 24.0f, 200.0f, 1, 56.0f, 200.0f, 4,
    };
    ab_fill_path(c, tri, (int32_t)(sizeof tri / sizeof tri[0]), accent);
    ab_stroke_line(c, 20.0f, 280.0f, width_dp - 20.0f, 280.0f, 2.0f, 1, 0x66FFFFFFu);

    float measured = ab_measure_text(c, "measured", 8, 13.0f, 400, 0, 0.0f);
    ab_draw_text(c, "measured", 8, width_dp - 20.0f - measured, 300.0f, 13.0f, 400, 0, secondary,
                 0);

    /* Bottom safe-area marker. */
    if (g_safe_bottom > 0.5f) {
        ab_fill_rect(c, 0, height_dp - g_safe_bottom, width_dp, height_dp - g_safe_bottom + 1.0f,
                     0x33FF0000u);
    }
}

void swiftui_android_touch(ABRuntime *rt, int32_t phase, float x_dp, float y_dp, int64_t time_ms) {
    (void)rt;
    (void)phase;
    (void)x_dp;
    (void)y_dp;
    (void)time_ms;
    /* Redraw with the latest resize values. */
    ab_invalidate(rt);
}

bool swiftui_android_key(ABRuntime *rt, int32_t action, int32_t key_code) {
    (void)rt;
    (void)action;
    (void)key_code;
    return false;
}

void swiftui_android_lifecycle(ABRuntime *rt, int32_t event) { (void)rt; (void)event; }

void swiftui_android_low_memory(ABRuntime *rt) { (void)rt; }
