/*
 * AndroidBridge.h — C boundary between Swift and the Android platform.
 *
 * Design rules:
 *   • Java objects (Canvas, Paint, Typeface, View) NEVER cross into Swift. All JNIEnv /
 *     jmethodID / jobject handling lives in AndroidBridge.c.
 *   • Swift sees only plain C values: floats in dp (density-independent points), uint32 ARGB,
 *     NUL-terminated UTF-8.
 *   • Every function here is called on the Android UI thread only.
 *
 * The coordinate system is top-left origin, +y down, measured in dp. The host View has already
 * applied canvas.scale(density, density), so 1 unit == 1 dp on screen.
 */
#ifndef ANDROID_BRIDGE_H
#define ANDROID_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABRuntime ABRuntime;
typedef struct ABCanvas  ABCanvas;

/* ────────────────────────────────────────────────────────────────────────────
 * 1. Entry points implemented by Swift (Sources/SwiftUIAndroid), invoked by the
 *    JNI functions in AndroidBridge.c.
 * ──────────────────────────────────────────────────────────────────────────── */

/* Called once when the host View is created (before the first resize/render). */
void swiftui_android_start(ABRuntime *rt);

/* Called from onSizeChanged and whenever window insets change. All values in dp. */
void swiftui_android_resize(ABRuntime *rt, float width_dp, float height_dp, float density,
                            float safe_top, float safe_bottom,
                            float safe_left, float safe_right);

/* Called from onDraw. `canvas` is only valid for the duration of this call. */
void swiftui_android_render(ABRuntime *rt, ABCanvas *canvas,
                            float width_dp, float height_dp, float density);

/* Touch: phase 0=down, 1=move, 2=up, 3=cancel. Coordinates already converted to dp. */
void swiftui_android_touch(ABRuntime *rt, int32_t phase, float x_dp, float y_dp, int64_t time_ms);

/* Hardware key: action 0=down 1=up. key_code uses Android KeyEvent codes
 * (4 = BACK). Returns true when the event was consumed by the SwiftUI layer. */
bool swiftui_android_key(ABRuntime *rt, int32_t action, int32_t key_code);

/* Activity lifecycle: 0=create 1=resume 2=pause 3=destroy. */
void swiftui_android_lifecycle(ABRuntime *rt, int32_t event);

void swiftui_android_low_memory(ABRuntime *rt);

/* ────────────────────────────────────────────────────────────────────────────
 * 2. Drawing primitives implemented by C on top of android.graphics.Canvas.
 * ──────────────────────────────────────────────────────────────────────────── */

/* --- canvas state --- */
void ab_save(ABCanvas *c);
void ab_restore(ABCanvas *c);
/* Clip to a rectangle; radius > 0 rounds the corners. Clips intersect with the
 * current clip (same semantics as Canvas.clipRect). */
void ab_clip_rect(ABCanvas *c, float l, float t, float r, float b);
void ab_clip_round_rect(ABCanvas *c, float l, float t, float r, float b, float radius);

/* --- filled primitives --- */
void ab_fill_rect(ABCanvas *c, float l, float t, float r, float b, uint32_t argb);
void ab_fill_round_rect(ABCanvas *c, float l, float t, float r, float b, float radius, uint32_t argb);
void ab_fill_oval(ABCanvas *c, float l, float t, float r, float b, uint32_t argb);

/* --- stroked primitives --- */
void ab_stroke_rect(ABCanvas *c, float l, float t, float r, float b, float width, uint32_t argb);
void ab_stroke_round_rect(ABCanvas *c, float l, float t, float r, float b, float radius,
                          float width, uint32_t argb);
void ab_stroke_line(ABCanvas *c, float x1, float y1, float x2, float y2,
                    float width, int32_t cap /*0=butt 1=round 2=square*/, uint32_t argb);

/* --- paths ---
 * Command stream of float32 values, opcode first:
 *   0 = moveTo(x, y)                          -> 1 + 2 floats
 *   1 = lineTo(x, y)                          -> 1 + 2 floats
 *   2 = quadTo(cx, cy, x, y)                  -> 1 + 4 floats
 *   3 = cubicTo(c1x, c1y, c2x, c2y, x, y)     -> 1 + 6 floats
 *   4 = close()                               -> 1 + 0 floats
 * `count` is the total number of floats. */
void ab_fill_path(ABCanvas *c, const float *cmds, int32_t count, uint32_t argb);
void ab_stroke_path(ABCanvas *c, const float *cmds, int32_t count, float width,
                    int32_t cap, int32_t join /*0=miter 1=round 2=bevel*/, uint32_t argb);

/* --- shadows --- */
void ab_draw_shadow_round_rect(ABCanvas *c, float l, float t, float r, float b,
                               float radius, float dx, float dy, float blur, uint32_t argb);

/* --- gradients --- */
void ab_fill_linear_gradient_rect(ABCanvas *c, float l, float t, float r, float b,
                                  float x0, float y0, float x1, float y1,
                                  const uint32_t *colors, const float *stops, int32_t count);
void ab_fill_linear_gradient_round_rect(ABCanvas *c, float l, float t, float r, float b,
                                        float radius, float x0, float y0, float x1, float y1,
                                        const uint32_t *colors, const float *stops, int32_t count);

/* --- text ---
 * `weight` is 100…900 (400 regular, 500 medium, 600 semibold, 700 bold); 0 means 400.
 * `size` is in dp. `baseline_y` is the text baseline. Returns the advance width in dp. */
void ab_draw_text(ABCanvas *c, const char *utf8, int32_t len, float x, float baseline_y,
                  float size, int32_t weight, int32_t italic, uint32_t color,
                  float letter_spacing);
float ab_measure_text(ABCanvas *c, const char *utf8, int32_t len, float size,
                      int32_t weight, int32_t italic, float letter_spacing);
/* Font vertical metrics in dp for the given style. `ascent` is negative (above baseline),
 * `descent` positive, like CoreText's ascent/descent. */
void ab_font_metrics(ABCanvas *c, float size, int32_t weight, int32_t italic,
                     float *ascent, float *descent, float *leading);

/* ────────────────────────────────────────────────────────────────────────────
 * 3. Utilities.
 * ──────────────────────────────────────────────────────────────────────────── */

/* Thread-safe: posts View.postInvalidate() so Android runs onDraw on the next vsync. */
void ab_invalidate(ABRuntime *rt);
/* Monotonic clock in seconds (SystemClock.uptimeMillis, cached VM). */
double ab_seconds_since_boot(void);
/* Device pixel ratio, available any time after the runtime is created. */
float ab_density(ABRuntime *rt);
/* True when the platform is in dark mode (Configuration.UI_MODE_NIGHT_YES). */
bool ab_is_dark_mode(ABRuntime *rt);

#ifdef __cplusplus
}
#endif

#endif /* ANDROID_BRIDGE_H */
