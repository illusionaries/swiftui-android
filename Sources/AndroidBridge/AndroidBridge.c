/*
 * AndroidBridge.c — JNI boundary between the SwiftUI runtime (Swift) and Android.
 *
 * This file owns *all* JNIEnv / jmethodID / jobject handling. Swift only ever sees the
 * plain-C surface declared in include/AndroidBridge.h:
 *
 *   • swiftui_android_*  — implemented by Swift (Sources/SwiftUIAndroid), called from here.
 *   • ab_*               — implemented here on top of android.graphics.Canvas, called by Swift.
 *
 * ── Host-side contract ──────────────────────────────────────────────────────────────
 * The Java class dev.swiftui.android.SwiftUIHostView loads "swiftui_app" and calls these
 * static native methods (mangled names below are what this file exports):
 *
 *   long      nativeCreate(SwiftUIHostView v)                 → Java_..._nativeCreate
 *   void      nativeResize(long h, int wPx, int hPx, float density,
 *                          float st, float sb, float sl, float sr)
 *   void      nativeDraw(long h, Canvas c, float wDp, float hDp, float density)
 *   boolean   nativeTouch(long h, int phase, float xDp, float yDp)
 *   boolean   nativeKey(long h, int action, int keyCode)
 *   void      nativeLifecycle(long h, int event)   [extra: attach/visible/pause/destroy]
 *   void      nativeLowMemory(long h)              [extra]
 *   void      nativeDestroy(long h)
 *
 * Each one marshals into the matching swiftui_android_* function in AndroidBridge.h.
 * All calls arrive on the Android UI thread; only ab_invalidate()/ab_seconds_since_boot()
 * may be called from other threads.
 *
 * Coordinate system: top-left origin, +y down, unit = dp. The Java View already applied
 * canvas.scale(density, density), so every float that crosses this boundary is dp.
 */
#include "AndroidBridge.h"

#include <jni.h>

#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ──────────────────────────────────────────────────────────────────────────────
 * 0. Logging.
 *
 * We do not want a hard link-time dependency on liblog (the SwiftPM target has no
 * linkerSettings we are allowed to touch), so the two liblog entry points we use are
 * weak symbols: they resolve to NULL when liblog is absent and every call is guarded.
 * ────────────────────────────────────────────────────────────────────────────── */
extern int __android_log_print(int prio, const char *tag, const char *fmt, ...)
    __attribute__((weak));

#define AB_LOG_TAG "AndroidBridge"
#define AB_LOGE(...)                                                                    \
    do {                                                                                \
        if (__android_log_print) {                                                      \
            __android_log_print(3 /* ANDROID_LOG_ERROR */, AB_LOG_TAG, __VA_ARGS__);    \
        }                                                                               \
    } while (0)

/* ──────────────────────────────────────────────────────────────────────────────
 * 1. Global state: the JavaVM plus a one-time cache of the framework classes and of the
 *    enum singletons (Paint.Style.FILL, Shader.TileMode.CLAMP, ...). Class lookups are
 *    expensive; they happen exactly once per process.
 * ────────────────────────────────────────────────────────────────────────────── */
typedef struct ABClasses {
    int ready;
    jclass paint;
    jclass canvas;
    jclass path;
    jclass rectf;
    jclass typeface;
    jclass font_metrics;
    jclass linear_gradient;
    jclass view;
    jclass resources;
    jclass configuration;
    jclass display_metrics;
    jclass system_clock;
    jclass context;

    jobject paint_style_fill;
    jobject paint_style_stroke;
    jobject paint_cap_butt;
    jobject paint_cap_round;
    jobject paint_cap_square;
    jobject paint_join_miter;
    jobject paint_join_round;
    jobject paint_join_bevel;
    jobject shader_tile_clamp;
    jobject path_direction_cw;
} ABClasses;

static JavaVM *g_vm = NULL;
static ABClasses g_cls;
static pthread_mutex_t g_cls_mutex = PTHREAD_MUTEX_INITIALIZER;

/* ──────────────────────────────────────────────────────────────────────────────
 * 2. Per-thread JNI cache.
 *
 * jmethodID/jfieldID values are tied to the JNIEnv that produced them in the JNI
 * specification, so the cache is thread-local and is rebuilt whenever the thread's
 * JNIEnv pointer changes (re-attach, VM reset, ...). This keeps us correct when the
 * runtime is touched from a thread other than the UI thread.
 * ────────────────────────────────────────────────────────────────────────────── */
typedef struct ABIds {
    JNIEnv *env;

    /* Paint */
    jmethodID paint_set_color;
    jmethodID paint_set_style;
    jmethodID paint_set_stroke_width;
    jmethodID paint_set_stroke_cap;
    jmethodID paint_set_stroke_join;
    jmethodID paint_set_anti_alias;
    jmethodID paint_set_dither;
    jmethodID paint_set_subpixel_text;
    jmethodID paint_set_text_size;
    jmethodID paint_set_text_align;
    jmethodID paint_set_typeface;
    jmethodID paint_set_letter_spacing;
    jmethodID paint_set_shader;
    jmethodID paint_set_shadow_layer;
    jmethodID paint_measure_text;
    jmethodID paint_get_font_metrics;
    jfieldID font_metrics_ascent;
    jfieldID font_metrics_descent;
    jfieldID font_metrics_leading;

    /* Canvas */
    jmethodID canvas_draw_rect;
    jmethodID canvas_draw_round_rect;
    jmethodID canvas_draw_oval;
    jmethodID canvas_draw_path;
    jmethodID canvas_draw_text;
    jmethodID canvas_draw_line;
    jmethodID canvas_save;
    jmethodID canvas_restore;
    jmethodID canvas_clip_rect;
    jmethodID canvas_clip_path;
    jmethodID canvas_translate;
    jmethodID canvas_scale;
    jmethodID canvas_get_width;
    jmethodID canvas_get_height;

    /* Path */
    jmethodID path_ctor;
    jmethodID path_rewind;
    jmethodID path_move_to;
    jmethodID path_line_to;
    jmethodID path_quad_to;
    jmethodID path_cubic_to;
    jmethodID path_close;
    jmethodID path_add_round_rect;

    /* RectF */
    jmethodID rectf_ctor;
    jmethodID rectf_set;

    /* Typeface */
    jmethodID typeface_create;

    /* Paint.FontMetrics */
    jmethodID font_metrics_ctor;

    /* LinearGradient */
    jmethodID linear_gradient_ctor;

    /* View */
    jmethodID view_post_invalidate;
    jmethodID view_get_resources;
    jmethodID view_get_context;

    /* Resources */
    jmethodID resources_get_configuration;
    jmethodID resources_get_display_metrics;

    /* Configuration / DisplayMetrics */
    jfieldID configuration_ui_mode;
    jfieldID display_metrics_density;

    /* SystemClock */
    jmethodID system_clock_uptime_millis;
} ABIds;

static __thread ABIds t_ids;

/* ──────────────────────────────────────────────────────────────────────────────
 * 3. Per-thread scratch objects: paints, path, rect, FontMetrics, typefaces, gradient
 *    arrays. Nothing here is allocated per draw call; a draw call only ever calls
 *    setters on an existing Paint. Rebuilt when the thread's JNIEnv changes.
 * ────────────────────────────────────────────────────────────────────────────── */
#define AB_TF_FAMILIES 3 /* 0 sans-serif, 1 sans-serif-medium, 2 sans-serif-light */
#define AB_TF_STYLES 4   /* 0 normal, 1 bold, 2 italic, 3 bold-italic */

typedef struct ABScratch {
    JNIEnv *env;

    jobject fill_paint;
    jobject stroke_paint;
    jobject text_paint;
    jobject gradient_paint;
    jobject shadow_paint;

    jobject path;
    jobject rectf;
    jobject font_metrics;

    jobject typefaces[AB_TF_FAMILIES][AB_TF_STYLES];

    jintArray gradient_colors;
    jfloatArray gradient_stops;
    int gradient_capacity;
} ABScratch;

static __thread ABScratch t_scratch;

/* ──────────────────────────────────────────────────────────────────────────────
 * 4. Trusted-thread TLS: when a thread attaches itself just to call us we detach it
 *    again from a pthread destructor instead of leaking an attached thread.
 * ────────────────────────────────────────────────────────────────────────────── */
static pthread_key_t g_tls_key;
static pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;

static void ab_tls_destructor(void *value) {
    if (value && g_vm) {
        (*g_vm)->DetachCurrentThread(g_vm);
    }
}

static void ab_tls_init(void) { (void)pthread_key_create(&g_tls_key, ab_tls_destructor); }

static JNIEnv *ab_env(void) {
    if (!g_vm) {
        return NULL;
    }
    JNIEnv *env = NULL;
    jint rc = (*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_OK && env) {
        return env;
    }
    if (rc != JNI_EDETACHED) {
        return NULL;
    }
    pthread_once(&g_tls_once, ab_tls_init);
    env = NULL;
    if ((*g_vm)->AttachCurrentThreadAsDaemon(g_vm, (void **)&env, NULL) != JNI_OK) {
        return NULL;
    }
    (void)pthread_setspecific(g_tls_key, (void *)1);
    return env;
}

/* ──────────────────────────────────────────────────────────────────────────────
 * 5. Class / id cache construction.
 * ────────────────────────────────────────────────────────────────────────────── */
static jclass ab_global_class(JNIEnv *env, const char *name) {
    jclass local = (*env)->FindClass(env, name);
    if (!local) {
        AB_LOGE("FindClass(%s) failed", name);
        return NULL;
    }
    jclass global = (jclass)(*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    return global;
}

static jobject ab_static_object(JNIEnv *env, jclass cls, const char *name, const char *sig) {
    jfieldID field = (*env)->GetStaticFieldID(env, cls, name, sig);
    if (!field) {
        AB_LOGE("GetStaticFieldID(%s) failed", name);
        return NULL;
    }
    jobject local = (*env)->GetStaticObjectField(env, cls, field);
    if (!local) {
        return NULL;
    }
    jobject global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    return global;
}

static int ab_classes_init(JNIEnv *env) {
    if (g_cls.ready) {
        return 1;
    }
    (void)pthread_mutex_lock(&g_cls_mutex);
    if (g_cls.ready) {
        (void)pthread_mutex_unlock(&g_cls_mutex);
        return 1;
    }

    int ok = 1;
    g_cls.paint = ab_global_class(env, "android/graphics/Paint");
    g_cls.canvas = ab_global_class(env, "android/graphics/Canvas");
    g_cls.path = ab_global_class(env, "android/graphics/Path");
    g_cls.rectf = ab_global_class(env, "android/graphics/RectF");
    g_cls.typeface = ab_global_class(env, "android/graphics/Typeface");
    g_cls.font_metrics = ab_global_class(env, "android/graphics/Paint$FontMetrics");
    g_cls.linear_gradient = ab_global_class(env, "android/graphics/LinearGradient");
    g_cls.view = ab_global_class(env, "android/view/View");
    g_cls.context = ab_global_class(env, "android/content/Context");
    g_cls.resources = ab_global_class(env, "android/content/res/Resources");
    g_cls.configuration = ab_global_class(env, "android/content/res/Configuration");
    g_cls.display_metrics = ab_global_class(env, "android/util/DisplayMetrics");
    g_cls.system_clock = ab_global_class(env, "android/os/SystemClock");

    ok = ok && g_cls.paint && g_cls.canvas && g_cls.path && g_cls.rectf && g_cls.typeface &&
         g_cls.font_metrics && g_cls.linear_gradient && g_cls.view && g_cls.resources &&
         g_cls.configuration && g_cls.display_metrics && g_cls.system_clock;

    if (ok) {
        g_cls.paint_style_fill = ab_static_object(env, g_cls.paint, "FILL", "Landroid/graphics/Paint$Style;");
        g_cls.paint_style_stroke = ab_static_object(env, g_cls.paint, "STROKE", "Landroid/graphics/Paint$Style;");
        g_cls.paint_cap_butt = ab_static_object(env, g_cls.paint, "BUTT", "Landroid/graphics/Paint$Cap;");
        g_cls.paint_cap_round = ab_static_object(env, g_cls.paint, "ROUND", "Landroid/graphics/Paint$Cap;");
        g_cls.paint_cap_square = ab_static_object(env, g_cls.paint, "SQUARE", "Landroid/graphics/Paint$Cap;");
        g_cls.paint_join_miter = ab_static_object(env, g_cls.paint, "MITER", "Landroid/graphics/Paint$Join;");
        g_cls.paint_join_round = ab_static_object(env, g_cls.paint, "ROUND", "Landroid/graphics/Paint$Join;");
        g_cls.paint_join_bevel = ab_static_object(env, g_cls.paint, "BEVEL", "Landroid/graphics/Paint$Join;");
        g_cls.shader_tile_clamp =
            ab_static_object(env, ab_global_class(env, "android/graphics/Shader$TileMode"), "CLAMP",
                             "Landroid/graphics/Shader$TileMode;");
        g_cls.path_direction_cw =
            ab_static_object(env, ab_global_class(env, "android/graphics/Path$Direction"), "CW",
                             "Landroid/graphics/Path$Direction;");
        ok = g_cls.paint_style_fill && g_cls.paint_style_stroke && g_cls.paint_cap_butt &&
             g_cls.paint_cap_round && g_cls.paint_cap_square && g_cls.paint_join_miter &&
             g_cls.paint_join_round && g_cls.paint_join_bevel && g_cls.shader_tile_clamp &&
             g_cls.path_direction_cw;
    }

    if (ok) {
        g_cls.ready = 1;
    }
    (void)pthread_mutex_unlock(&g_cls_mutex);
    return ok;
}

#define AB_MID(ids, cls, name, sig, field)                                              \
    do {                                                                                \
        (ids)->field = (*env)->GetMethodID(env, (cls), (name), (sig));                  \
        if (!(ids)->field) {                                                            \
            AB_LOGE("GetMethodID %s%s failed", (name), (sig));                          \
            ok = 0;                                                                     \
        }                                                                               \
    } while (0)

#define AB_SMID(ids, cls, name, sig, field)                                             \
    do {                                                                                \
        (ids)->field = (*env)->GetStaticMethodID(env, (cls), (name), (sig));            \
        if (!(ids)->field) {                                                            \
            AB_LOGE("GetStaticMethodID %s%s failed", (name), (sig));                    \
            ok = 0;                                                                     \
        }                                                                               \
    } while (0)

static int ab_ids_init(JNIEnv *env, ABIds *ids) {
    if (ids->env == env) {
        return 1;
    }
    memset(ids, 0, sizeof(*ids));
    ids->env = env;

    int ok = 1;
    jclass c = g_cls.paint;
    AB_MID(ids, c, "setColor", "(I)V", paint_set_color);
    AB_MID(ids, c, "setStyle", "(Landroid/graphics/Paint$Style;)V", paint_set_style);
    AB_MID(ids, c, "setStrokeWidth", "(F)V", paint_set_stroke_width);
    AB_MID(ids, c, "setStrokeCap", "(Landroid/graphics/Paint$Cap;)V", paint_set_stroke_cap);
    AB_MID(ids, c, "setStrokeJoin", "(Landroid/graphics/Paint$Join;)V", paint_set_stroke_join);
    AB_MID(ids, c, "setAntiAlias", "(Z)V", paint_set_anti_alias);
    AB_MID(ids, c, "setDither", "(Z)V", paint_set_dither);
    AB_MID(ids, c, "setSubpixelText", "(Z)V", paint_set_subpixel_text);
    AB_MID(ids, c, "setTextSize", "(F)V", paint_set_text_size);
    AB_MID(ids, c, "setTextAlign", "(Landroid/graphics/Paint$Align;)V", paint_set_text_align);
    AB_MID(ids, c, "setTypeface", "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;",
           paint_set_typeface);
    AB_MID(ids, c, "setLetterSpacing", "(F)V", paint_set_letter_spacing);
    AB_MID(ids, c, "setShader", "(Landroid/graphics/Shader;)Landroid/graphics/Shader;", paint_set_shader);
    AB_MID(ids, c, "setShadowLayer", "(FFFI)V", paint_set_shadow_layer);
    AB_MID(ids, c, "measureText", "(Ljava/lang/String;)F", paint_measure_text);
    AB_MID(ids, c, "getFontMetrics", "(Landroid/graphics/Paint$FontMetrics;)F",
           paint_get_font_metrics);

    c = g_cls.font_metrics;
    AB_MID(ids, c, "<init>", "()V", font_metrics_ctor);
    ids->font_metrics_ascent = (*env)->GetFieldID(env, c, "ascent", "F");
    ids->font_metrics_descent = (*env)->GetFieldID(env, c, "descent", "F");
    ids->font_metrics_leading = (*env)->GetFieldID(env, c, "leading", "F");
    if (!ids->font_metrics_ascent || !ids->font_metrics_descent || !ids->font_metrics_leading) {
        AB_LOGE("Paint$FontMetrics fields missing");
        ok = 0;
    }

    c = g_cls.canvas;
    AB_MID(ids, c, "drawRect", "(FFFFLandroid/graphics/Paint;)V", canvas_draw_rect);
    AB_MID(ids, c, "drawRoundRect", "(FFFFFFLandroid/graphics/Paint;)V", canvas_draw_round_rect);
    AB_MID(ids, c, "drawOval", "(FFFFLandroid/graphics/Paint;)V", canvas_draw_oval);
    AB_MID(ids, c, "drawPath", "(Landroid/graphics/Path;Landroid/graphics/Paint;)V", canvas_draw_path);
    AB_MID(ids, c, "drawText", "(Ljava/lang/String;FFLandroid/graphics/Paint;)V", canvas_draw_text);
    AB_MID(ids, c, "drawLine", "(FFFFLandroid/graphics/Paint;)V", canvas_draw_line);
    AB_MID(ids, c, "save", "()I", canvas_save);
    AB_MID(ids, c, "restore", "()V", canvas_restore);
    AB_MID(ids, c, "clipRect", "(FFFF)Z", canvas_clip_rect);
    AB_MID(ids, c, "clipPath", "(Landroid/graphics/Path;)Z", canvas_clip_path);
    AB_MID(ids, c, "translate", "(FF)V", canvas_translate);
    AB_MID(ids, c, "scale", "(FF)V", canvas_scale);
    AB_MID(ids, c, "getWidth", "()I", canvas_get_width);
    AB_MID(ids, c, "getHeight", "()I", canvas_get_height);

    c = g_cls.path;
    AB_MID(ids, c, "<init>", "()V", path_ctor);
    AB_MID(ids, c, "rewind", "()V", path_rewind);
    AB_MID(ids, c, "moveTo", "(FF)V", path_move_to);
    AB_MID(ids, c, "lineTo", "(FF)V", path_line_to);
    AB_MID(ids, c, "quadTo", "(FFFF)V", path_quad_to);
    AB_MID(ids, c, "cubicTo", "(FFFFFF)V", path_cubic_to);
    AB_MID(ids, c, "close", "()V", path_close);
    AB_MID(ids, c, "addRoundRect", "(FFFFFFLandroid/graphics/Path$Direction;)V", path_add_round_rect);

    c = g_cls.rectf;
    AB_MID(ids, c, "<init>", "(FFFF)V", rectf_ctor);
    AB_MID(ids, c, "set", "(FFFF)V", rectf_set);

    c = g_cls.typeface;
    AB_SMID(ids, c, "create", "(Ljava/lang/String;I)Landroid/graphics/Typeface;", typeface_create);

    c = g_cls.linear_gradient;
    AB_MID(ids, c, "<init>", "(FFFF[I[FLandroid/graphics/Shader$TileMode;)V", linear_gradient_ctor);

    c = g_cls.view;
    AB_MID(ids, c, "postInvalidate", "()V", view_post_invalidate);
    AB_MID(ids, c, "getResources", "()Landroid/content/res/Resources;", view_get_resources);
    AB_MID(ids, c, "getContext", "()Landroid/content/Context;", view_get_context);

    c = g_cls.resources;
    AB_MID(ids, c, "getConfiguration", "()Landroid/content/res/Configuration;", resources_get_configuration);
    AB_MID(ids, c, "getDisplayMetrics", "()Landroid/util/DisplayMetrics;", resources_get_display_metrics);

    ids->configuration_ui_mode = (*env)->GetFieldID(env, g_cls.configuration, "uiMode", "I");
    ids->display_metrics_density = (*env)->GetFieldID(env, g_cls.display_metrics, "density", "F");
    if (!ids->configuration_ui_mode || !ids->display_metrics_density) {
        AB_LOGE("Configuration.uiMode / DisplayMetrics.density field missing");
        ok = 0;
    }

    AB_SMID(ids, g_cls.system_clock, "uptimeMillis", "()J", system_clock_uptime_millis);

    if (!ok) {
        ids->env = NULL;
    }
    return ok;
}

#undef AB_MID
#undef AB_SMID

/* ──────────────────────────────────────────────────────────────────────────────
 * 6. Per-thread scratch objects.
 * ────────────────────────────────────────────────────────────────────────────── */
static void ab_scratch_release(JNIEnv *env, ABScratch *s) {
    if (!s->env) {
        return;
    }
    jobject *objects[] = {
        &s->fill_paint,   &s->stroke_paint, &s->text_paint, &s->gradient_paint,
        &s->shadow_paint, &s->path,         &s->rectf,      &s->font_metrics,
    };
    for (size_t i = 0; i < sizeof(objects) / sizeof(objects[0]); i++) {
        if (*objects[i]) {
            (*env)->DeleteGlobalRef(env, *objects[i]);
            *objects[i] = NULL;
        }
    }
    for (int f = 0; f < AB_TF_FAMILIES; f++) {
        for (int st = 0; st < AB_TF_STYLES; st++) {
            if (s->typefaces[f][st]) {
                (*env)->DeleteGlobalRef(env, s->typefaces[f][st]);
                s->typefaces[f][st] = NULL;
            }
        }
    }
    if (s->gradient_colors) {
        (*env)->DeleteGlobalRef(env, s->gradient_colors);
        s->gradient_colors = NULL;
    }
    if (s->gradient_stops) {
        (*env)->DeleteGlobalRef(env, s->gradient_stops);
        s->gradient_stops = NULL;
    }
    s->gradient_capacity = 0;
    s->env = NULL;
}

/* Paint.<init>()V — resolved once per scratch init (the id is only needed here). */
static jobject ab_alloc_paint(JNIEnv *env, jmethodID paint_ctor) {
    jobject local = (*env)->NewObject(env, g_cls.paint, paint_ctor);
    if (!local) {
        AB_LOGE("NewObject(Paint) failed");
        return NULL;
    }
    jobject global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    return global;
}

static int ab_scratch_init(JNIEnv *env, ABIds *ids, ABScratch *s) {
    if (s->env == env) {
        return 1;
    }
    if (s->env) {
        ab_scratch_release(env, s);
    }
    memset(s, 0, sizeof(*s));
    s->env = env;

    jmethodID paint_ctor = (*env)->GetMethodID(env, g_cls.paint, "<init>", "()V");
    if (!paint_ctor) {
        AB_LOGE("Paint.<init> missing");
        s->env = NULL;
        return 0;
    }
    s->fill_paint = ab_alloc_paint(env, paint_ctor);
    s->stroke_paint = ab_alloc_paint(env, paint_ctor);
    s->text_paint = ab_alloc_paint(env, paint_ctor);
    s->gradient_paint = ab_alloc_paint(env, paint_ctor);
    s->shadow_paint = ab_alloc_paint(env, paint_ctor);
    if (!s->fill_paint || !s->stroke_paint || !s->text_paint || !s->gradient_paint ||
        !s->shadow_paint) {
        s->env = NULL;
        return 0;
    }

    /* Paints that are configured once and only get a colour (and text metrics) changed. */
    (*env)->CallVoidMethod(env, s->fill_paint, ids->paint_set_anti_alias, JNI_TRUE);
    (*env)->CallVoidMethod(env, s->fill_paint, ids->paint_set_style, g_cls.paint_style_fill);
    (*env)->CallVoidMethod(env, s->fill_paint, ids->paint_set_dither, JNI_TRUE);

    (*env)->CallVoidMethod(env, s->stroke_paint, ids->paint_set_anti_alias, JNI_TRUE);
    (*env)->CallVoidMethod(env, s->stroke_paint, ids->paint_set_style, g_cls.paint_style_stroke);
    (*env)->CallVoidMethod(env, s->stroke_paint, ids->paint_set_stroke_cap, g_cls.paint_cap_butt);
    (*env)->CallVoidMethod(env, s->stroke_paint, ids->paint_set_stroke_join, g_cls.paint_join_miter);

    (*env)->CallVoidMethod(env, s->text_paint, ids->paint_set_anti_alias, JNI_TRUE);
    (*env)->CallVoidMethod(env, s->text_paint, ids->paint_set_subpixel_text, JNI_TRUE);
    (*env)->CallVoidMethod(env, s->text_paint, ids->paint_set_dither, JNI_TRUE);

    (*env)->CallVoidMethod(env, s->gradient_paint, ids->paint_set_anti_alias, JNI_TRUE);
    (*env)->CallVoidMethod(env, s->gradient_paint, ids->paint_set_style, g_cls.paint_style_fill);

    (*env)->CallVoidMethod(env, s->shadow_paint, ids->paint_set_anti_alias, JNI_TRUE);
    (*env)->CallVoidMethod(env, s->shadow_paint, ids->paint_set_style, g_cls.paint_style_fill);

    s->path = (*env)->NewObject(env, g_cls.path, ids->path_ctor);
    if (s->path) {
        jobject g = (*env)->NewGlobalRef(env, s->path);
        (*env)->DeleteLocalRef(env, s->path);
        s->path = g;
    }
    s->rectf = (*env)->NewObject(env, g_cls.rectf, ids->rectf_ctor, 0.0f, 0.0f, 0.0f, 0.0f);
    if (s->rectf) {
        jobject g = (*env)->NewGlobalRef(env, s->rectf);
        (*env)->DeleteLocalRef(env, s->rectf);
        s->rectf = g;
    }
    s->font_metrics = (*env)->NewObject(env, g_cls.font_metrics, ids->font_metrics_ctor);
    if (s->font_metrics) {
        jobject g = (*env)->NewGlobalRef(env, s->font_metrics);
        (*env)->DeleteLocalRef(env, s->font_metrics);
        s->font_metrics = g;
    }

    if (!s->path || !s->rectf || !s->font_metrics) {
        s->env = NULL;
        return 0;
    }
    return 1;
}

/* ──────────────────────────────────────────────────────────────────────────────
 * 7. Runtime + canvas handles.
 * ────────────────────────────────────────────────────────────────────────────── */
struct ABRuntime {
    JavaVM *vm;
    jobject view; /* global ref, alive until nativeDestroy */
    jmethodID post_invalidate;
    jmethodID view_get_resources;
    jmethodID resources_get_configuration;
    jmethodID resources_get_display_metrics;
    jfieldID configuration_ui_mode;
    jfieldID display_metrics_density;

    float density;
    bool dark;
    int32_t width_px;
    int32_t height_px;
    float safe_top, safe_bottom, safe_left, safe_right;
};

struct ABCanvas {
    JNIEnv *env;
    jobject canvas; /* borrowed local ref, valid only for the duration of onDraw */
    ABIds *ids;
    ABScratch *scratch;
    float density;
};

/* ──────────────────────────────────────────────────────────────────────────────
 * 8. JNI_OnLoad / JNI_OnUnload.
 * ────────────────────────────────────────────────────────────────────────────── */
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;

    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK || !env) {
        return JNI_ERR;
    }
    if (!ab_classes_init(env)) {
        AB_LOGE("class cache init failed");
        return JNI_ERR;
    }
    if (!ab_ids_init(env, &t_ids)) {
        AB_LOGE("method id cache init failed");
        return JNI_ERR;
    }
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM *vm, void *reserved) {
    (void)reserved;
    (void)vm;
    /* The process is going away; the VM drops all global refs. Nothing to do. */
}

/* ──────────────────────────────────────────────────────────────────────────────
 * 9. Small helpers.
 * ────────────────────────────────────────────────────────────────────────────── */
static int ab_clear_exception(JNIEnv *env) {
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 1;
    }
    return 0;
}

static jstring ab_new_string(JNIEnv *env, const char *s, int32_t len) {
    if (!s) {
        return NULL;
    }
    if (len < 0) {
        len = (int32_t)strlen(s);
    }
    if (len == 0) {
        return (*env)->NewStringUTF(env, "");
    }

    char stackbuf[512];
    char *buf = stackbuf;
    if (len >= (int32_t)sizeof(stackbuf)) {
        buf = (char *)malloc((size_t)len + 1);
        if (!buf) {
            return NULL;
        }
    }
    memcpy(buf, s, (size_t)len);
    buf[len] = '\0';

    jstring result = NULL;
    int ascii = 1;
    for (int32_t i = 0; i < len; i++) {
        if ((unsigned char)buf[i] >= 0x80) {
            ascii = 0;
            break;
        }
    }

    if (ascii) {
        /* Pure ASCII is identical in modified UTF-8: no copy on the Java side needed. */
        result = (*env)->NewStringUTF(env, buf);
    } else {
        /* Decode standard UTF-8 to UTF-16 and hand it to NewString. This is what makes
         * 4-byte sequences (emoji) come out right: NewStringUTF expects *modified*
         * UTF-8, so a raw 4-byte sequence would be mis-decoded. */
        jchar *units = (jchar *)malloc(((size_t)len + 1) * sizeof(jchar));
        if (units) {
            size_t n = 0;
            const unsigned char *p = (const unsigned char *)buf;
            int32_t i = 0;
            while (i < len) {
                unsigned char c0 = p[i];
                uint32_t cp = 0xFFFD;
                int adv = 1;
                if (c0 < 0x80) {
                    cp = c0;
                } else if ((c0 & 0xE0) == 0xC0 && i + 1 < len) {
                    cp = ((uint32_t)(c0 & 0x1F) << 6) | (uint32_t)(p[i + 1] & 0x3F);
                    adv = 2;
                } else if ((c0 & 0xF0) == 0xE0 && i + 2 < len) {
                    cp = ((uint32_t)(c0 & 0x0F) << 12) | ((uint32_t)(p[i + 1] & 0x3F) << 6) |
                         (uint32_t)(p[i + 2] & 0x3F);
                    adv = 3;
                } else if ((c0 & 0xF8) == 0xF0 && i + 3 < len) {
                    cp = ((uint32_t)(c0 & 0x07) << 18) | ((uint32_t)(p[i + 1] & 0x3F) << 12) |
                         ((uint32_t)(p[i + 2] & 0x3F) << 6) | (uint32_t)(p[i + 3] & 0x3F);
                    adv = 4;
                }
                if (cp > 0x10FFFFu || (cp >= 0xD800u && cp <= 0xDFFFu)) {
                    cp = 0xFFFD;
                }
                if (cp >= 0x10000u) {
                    cp -= 0x10000u;
                    units[n++] = (jchar)(0xD800u + (cp >> 10));
                    units[n++] = (jchar)(0xDC00u + (cp & 0x3FFu));
                } else {
                    units[n++] = (jchar)cp;
                }
                i += adv;
            }
            result = (*env)->NewString(env, units, (jsize)n);
            free(units);
        }
    }

    if (buf != stackbuf) {
        free(buf);
    }
    return result;
}

/* Typeface for a (weight, italic) pair. Cached per thread; the returned object is owned by
 * the scratch cache and must not be deleted. */
static jobject ab_typeface(JNIEnv *env, ABIds *ids, ABScratch *s, int32_t weight, int32_t italic) {
    int32_t w = weight <= 0 ? 400 : weight;
    int family;
    if (w < 350) {
        family = 2; /* sans-serif-light */
    } else if (w <= 450) {
        family = 0; /* sans-serif */
    } else if (w <= 600) {
        family = 1; /* sans-serif-medium */
    } else {
        family = 0; /* sans-serif + bold style */
    }
    int bold = (w >= 600) ? 1 : 0;
    int style = (bold ? 1 : 0) | (italic ? 2 : 0);

    if (s->typefaces[family][style]) {
        return s->typefaces[family][style];
    }

    static const char *kFamilies[AB_TF_FAMILIES] = {
        "sans-serif",
        "sans-serif-medium",
        "sans-serif-light",
    };
    jstring name = (*env)->NewStringUTF(env, kFamilies[family]);
    if (!name) {
        return NULL;
    }
    jobject local = (*env)->CallStaticObjectMethod(env, g_cls.typeface, ids->typeface_create, name,
                                                   (jint)style);
    (*env)->DeleteLocalRef(env, name);
    if (!local) {
        ab_clear_exception(env);
        return NULL;
    }
    jobject global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    s->typefaces[family][style] = global;
    return global;
}

/* Configure the shared text paint for a style. Returns the paint to draw/measure with. */
static jobject ab_text_paint(JNIEnv *env, ABCanvas *c, float size, int32_t weight, int32_t italic,
                             float letter_spacing) {
    ABIds *ids = c->ids;
    ABScratch *s = c->scratch;
    jobject paint = s->text_paint;

    (*env)->CallVoidMethod(env, paint, ids->paint_set_text_size, (jfloat)size);
    jobject typeface = ab_typeface(env, ids, s, weight, italic);
    if (typeface) {
        (*env)->CallObjectMethod(env, paint, ids->paint_set_typeface, typeface);
    }
    (*env)->CallVoidMethod(env, paint, ids->paint_set_letter_spacing, (jfloat)letter_spacing);
    ab_clear_exception(env);
    return paint;
}

/* letterSpacing is specified in em units on Android: dp / size. */
static float ab_letter_spacing_em(float letter_spacing_dp, float size_dp) {
    if (size_dp <= 0.0f) {
        return 0.0f;
    }
    return letter_spacing_dp / size_dp;
}

/* ──────────────────────────────────────────────────────────────────────────────
 * 10. JNI entry points called by dev.swiftui.android.SwiftUIHostView.
 * ────────────────────────────────────────────────────────────────────────────── */
static void ab_runtime_refresh_configuration(JNIEnv *env, ABRuntime *rt) {
    jobject resources = (*env)->CallObjectMethod(env, rt->view, rt->view_get_resources);
    if (!resources || ab_clear_exception(env)) {
        return;
    }
    jobject metrics =
        (*env)->CallObjectMethod(env, resources, rt->resources_get_display_metrics);
    if (metrics) {
        jfloat density = (*env)->GetFloatField(env, metrics, rt->display_metrics_density);
        if (density > 0.0f) {
            rt->density = (float)density;
        }
        (*env)->DeleteLocalRef(env, metrics);
    }
    jobject config = (*env)->CallObjectMethod(env, resources, rt->resources_get_configuration);
    if (config) {
        jint ui_mode = (*env)->GetIntField(env, config, rt->configuration_ui_mode);
        rt->dark = ((ui_mode & 0x30 /* UI_MODE_NIGHT_MASK */) == 0x20 /* NIGHT_YES */);
        (*env)->DeleteLocalRef(env, config);
    }
    (*env)->DeleteLocalRef(env, resources);
    ab_clear_exception(env);
}

static ABRuntime *ab_runtime(jlong handle) {
    if (handle == 0) {
        return NULL;
    }
    return (ABRuntime *)(intptr_t)handle;
}

JNIEXPORT jlong JNICALL
Java_dev_swiftui_android_SwiftUIHostView_nativeCreate(JNIEnv *env, jclass clazz, jobject view) {
    (void)clazz;
    if (!view) {
        AB_LOGE("nativeCreate: null view");
        return 0;
    }
    if (!g_vm && (*env)->GetJavaVM(env, &g_vm) != JNI_OK) {
        AB_LOGE("nativeCreate: no JavaVM");
        return 0;
    }
    if (!ab_classes_init(env) || !ab_ids_init(env, &t_ids)) {
        AB_LOGE("nativeCreate: JNI caches unavailable");
        return 0;
    }

    ABRuntime *rt = (ABRuntime *)calloc(1, sizeof(ABRuntime));
    if (!rt) {
        return 0;
    }
    rt->vm = g_vm;
    rt->density = 1.0f;
    rt->view = (*env)->NewGlobalRef(env, view);
    if (!rt->view) {
        free(rt);
        return 0;
    }
    rt->view_get_resources =
        (*env)->GetMethodID(env, g_cls.view, "getResources", "()Landroid/content/res/Resources;");
    rt->resources_get_configuration =
        (*env)->GetMethodID(env, g_cls.resources, "getConfiguration",
                            "()Landroid/content/res/Configuration;");
    rt->resources_get_display_metrics =
        (*env)->GetMethodID(env, g_cls.resources, "getDisplayMetrics",
                            "()Landroid/util/DisplayMetrics;");
    rt->configuration_ui_mode = (*env)->GetFieldID(env, g_cls.configuration, "uiMode", "I");
    rt->display_metrics_density = (*env)->GetFieldID(env, g_cls.display_metrics, "density", "F");
    rt->post_invalidate = (*env)->GetMethodID(env, g_cls.view, "postInvalidate", "()V");
    if (!rt->post_invalidate) {
        ab_clear_exception(env);
    }

    ab_runtime_refresh_configuration(env, rt);
    ab_clear_exception(env);

    swiftui_android_start(rt);
    return (jlong)(intptr_t)rt;
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeResize(
    JNIEnv *env, jclass clazz, jlong handle, jint width_px, jint height_px, jfloat density,
    jfloat safe_top, jfloat safe_bottom, jfloat safe_left, jfloat safe_right) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt) {
        return;
    }
    ab_runtime_refresh_configuration(env, rt);
    rt->width_px = width_px;
    rt->height_px = height_px;
    if (density > 0.0f) {
        rt->density = (float)density;
    }
    rt->safe_top = safe_top;
    rt->safe_bottom = safe_bottom;
    rt->safe_left = safe_left;
    rt->safe_right = safe_right;

    float d = rt->density > 0.0f ? rt->density : 1.0f;
    float width_dp = (float)width_px / d;
    float height_dp = (float)height_px / d;
    swiftui_android_resize(rt, width_dp, height_dp, d, safe_top, safe_bottom, safe_left, safe_right);
    ab_clear_exception(env);
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeConfiguration(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt) {
        return;
    }
    ab_runtime_refresh_configuration(env, rt);
    float d = rt->density > 0.0f ? rt->density : 1.0f;
    swiftui_android_resize(rt, (float)rt->width_px / d, (float)rt->height_px / d, d, rt->safe_top,
                           rt->safe_bottom, rt->safe_left, rt->safe_right);
    ab_clear_exception(env);
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeDraw(
    JNIEnv *env, jclass clazz, jlong handle, jobject canvas, jfloat width_dp, jfloat height_dp,
    jfloat density) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt || !canvas) {
        return;
    }
    ABIds *ids = &t_ids;
    if (!ab_ids_init(env, ids)) {
        return;
    }
    ABScratch *scratch = &t_scratch;
    if (!ab_scratch_init(env, ids, scratch)) {
        return;
    }
    if ((*env)->PushLocalFrame(env, 32) != 0) {
        return;
    }

    ABCanvas c;
    memset(&c, 0, sizeof(c));
    c.env = env;
    c.canvas = canvas;
    c.ids = ids;
    c.scratch = scratch;
    c.density = density > 0.0f ? (float)density : rt->density;

    swiftui_android_render(rt, &c, width_dp, height_dp, c.density);
    ab_clear_exception(env);
    (void)(*env)->PopLocalFrame(env, NULL);
}

JNIEXPORT jboolean JNICALL
Java_dev_swiftui_android_SwiftUIHostView_nativeTouch(JNIEnv *env, jclass clazz, jlong handle,
                                                    jint phase, jfloat x_dp, jfloat y_dp) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt) {
        return JNI_FALSE;
    }
    /* Monotonic millisecond timestamps: identical timestamps would break gesture recognisers
     * that divide by dt, so force strict monotonicity for same-millisecond events. */
    static int64_t last_ms = 0;
    int64_t now_ms = 0;
    if (ab_ids_init(env, &t_ids)) {
        jlong up = (*env)->CallStaticLongMethod(env, g_cls.system_clock,
                                               t_ids.system_clock_uptime_millis);
        if (!ab_clear_exception(env)) {
            now_ms = (int64_t)up;
        }
    }
    if (now_ms <= 0) {
        now_ms = (int64_t)(ab_seconds_since_boot() * 1000.0);
    }
    if (now_ms <= last_ms) {
        now_ms = last_ms + 1;
    }
    last_ms = now_ms;

    swiftui_android_touch(rt, (int32_t)phase, x_dp, y_dp, now_ms);
    ab_clear_exception(env);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeKey(
    JNIEnv *env, jclass clazz, jlong handle, jint action, jint key_code) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt) {
        return JNI_FALSE;
    }
    bool consumed = swiftui_android_key(rt, (int32_t)action, (int32_t)key_code);
    ab_clear_exception(env);
    return consumed ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeLifecycle(
    JNIEnv *env, jclass clazz, jlong handle, jint event) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt) {
        return;
    }
    swiftui_android_lifecycle(rt, (int32_t)event);
    ab_clear_exception(env);
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeLowMemory(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt) {
        return;
    }
    swiftui_android_low_memory(rt);
    ab_clear_exception(env);
}

JNIEXPORT void JNICALL
Java_dev_swiftui_android_SwiftUIHostView_nativeDestroy(JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    ABRuntime *rt = ab_runtime(handle);
    if (!rt) {
        return;
    }
    swiftui_android_lifecycle(rt, 3 /* destroy */);
    ab_clear_exception(env);
    if (rt->view) {
        (*env)->DeleteGlobalRef(env, rt->view);
        rt->view = NULL;
    }
    free(rt);
}

/* ──────────────────────────────────────────────────────────────────────────────
 * 11. Drawing primitives (called by Swift on the UI thread during render).
 * ────────────────────────────────────────────────────────────────────────────── */
static void ab_paint_color(JNIEnv *env, jobject paint, ABIds *ids, uint32_t argb) {
    (*env)->CallVoidMethod(env, paint, ids->paint_set_color, (jint)argb);
}

void ab_save(ABCanvas *c) {
    if (!c) {
        return;
    }
    (*c->env)->CallIntMethod(c->env, c->canvas, c->ids->canvas_save);
}

void ab_restore(ABCanvas *c) {
    if (!c) {
        return;
    }
    (*c->env)->CallVoidMethod(c->env, c->canvas, c->ids->canvas_restore);
}

void ab_clip_rect(ABCanvas *c, float l, float t, float r, float b) {
    if (!c) {
        return;
    }
    (*c->env)->CallBooleanMethod(c->env, c->canvas, c->ids->canvas_clip_rect, l, t, r, b);
}

void ab_clip_round_rect(ABCanvas *c, float l, float t, float r, float b, float radius) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    ABIds *ids = c->ids;
    jobject path = c->scratch->path;
    (*env)->CallVoidMethod(env, path, ids->path_rewind);
    (*env)->CallVoidMethod(env, path, ids->path_add_round_rect, l, t, r, b, radius, radius,
                           g_cls.path_direction_cw);
    (*env)->CallBooleanMethod(env, c->canvas, ids->canvas_clip_path, path);
}

void ab_fill_rect(ABCanvas *c, float l, float t, float r, float b, uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject paint = c->scratch->fill_paint;
    ab_paint_color(env, paint, c->ids, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_rect, l, t, r, b, paint);
}

void ab_fill_round_rect(ABCanvas *c, float l, float t, float r, float b, float radius,
                        uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject paint = c->scratch->fill_paint;
    ab_paint_color(env, paint, c->ids, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_round_rect, l, t, r, b, radius,
                           radius, paint);
}

void ab_fill_oval(ABCanvas *c, float l, float t, float r, float b, uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject paint = c->scratch->fill_paint;
    ab_paint_color(env, paint, c->ids, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_oval, l, t, r, b, paint);
}

static jobject ab_stroke_paint(JNIEnv *env, ABCanvas *c, float width, int32_t cap, int32_t join,
                               uint32_t argb) {
    ABIds *ids = c->ids;
    jobject paint = c->scratch->stroke_paint;
    ab_paint_color(env, paint, ids, argb);
    (*env)->CallVoidMethod(env, paint, ids->paint_set_stroke_width, (jfloat)width);
    jobject cap_obj = g_cls.paint_cap_butt;
    if (cap == 1) {
        cap_obj = g_cls.paint_cap_round;
    } else if (cap == 2) {
        cap_obj = g_cls.paint_cap_square;
    }
    (*env)->CallVoidMethod(env, paint, ids->paint_set_stroke_cap, cap_obj);
    if (join >= 0) {
        jobject join_obj = g_cls.paint_join_miter;
        if (join == 1) {
            join_obj = g_cls.paint_join_round;
        } else if (join == 2) {
            join_obj = g_cls.paint_join_bevel;
        }
        (*env)->CallVoidMethod(env, paint, ids->paint_set_stroke_join, join_obj);
    }
    return paint;
}

void ab_stroke_rect(ABCanvas *c, float l, float t, float r, float b, float width, uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject paint = ab_stroke_paint(env, c, width, -1, -1, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_rect, l, t, r, b, paint);
}

void ab_stroke_round_rect(ABCanvas *c, float l, float t, float r, float b, float radius,
                          float width, uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject paint = ab_stroke_paint(env, c, width, -1, -1, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_round_rect, l, t, r, b, radius,
                           radius, paint);
}

void ab_stroke_line(ABCanvas *c, float x1, float y1, float x2, float y2, float width,
                    int32_t cap, uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject paint = ab_stroke_paint(env, c, width, cap, -1, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_line, x1, y1, x2, y2, paint);
}

/* Build the shared Path object from the float command stream documented in the header. */
static jobject ab_build_path(JNIEnv *env, ABCanvas *c, const float *cmds, int32_t count) {
    if (!cmds || count <= 0) {
        return NULL;
    }
    ABIds *ids = c->ids;
    jobject path = c->scratch->path;
    (*env)->CallVoidMethod(env, path, ids->path_rewind);

    int32_t i = 0;
    while (i < count) {
        int32_t op = (int32_t)cmds[i];
        i += 1;
        switch (op) {
        case 0: /* moveTo(x, y) */
            if (i + 1 >= count) {
                return path;
            }
            (*env)->CallVoidMethod(env, path, ids->path_move_to, cmds[i], cmds[i + 1]);
            i += 2;
            break;
        case 1: /* lineTo(x, y) */
            if (i + 1 >= count) {
                return path;
            }
            (*env)->CallVoidMethod(env, path, ids->path_line_to, cmds[i], cmds[i + 1]);
            i += 2;
            break;
        case 2: /* quadTo(cx, cy, x, y) */
            if (i + 3 >= count) {
                return path;
            }
            (*env)->CallVoidMethod(env, path, ids->path_quad_to, cmds[i], cmds[i + 1], cmds[i + 2],
                                   cmds[i + 3]);
            i += 4;
            break;
        case 3: /* cubicTo(c1x, c1y, c2x, c2y, x, y) */
            if (i + 5 >= count) {
                return path;
            }
            (*env)->CallVoidMethod(env, path, ids->path_cubic_to, cmds[i], cmds[i + 1], cmds[i + 2],
                                   cmds[i + 3], cmds[i + 4], cmds[i + 5]);
            i += 6;
            break;
        case 4: /* close() */
            (*env)->CallVoidMethod(env, path, ids->path_close);
            break;
        default:
            /* Unknown opcode: stop rather than run off the end. */
            return path;
        }
    }
    return path;
}

void ab_fill_path(ABCanvas *c, const float *cmds, int32_t count, uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject path = ab_build_path(env, c, cmds, count);
    if (!path) {
        return;
    }
    jobject paint = c->scratch->fill_paint;
    ab_paint_color(env, paint, c->ids, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_path, path, paint);
}

void ab_stroke_path(ABCanvas *c, const float *cmds, int32_t count, float width, int32_t cap,
                    int32_t join, uint32_t argb) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject path = ab_build_path(env, c, cmds, count);
    if (!path) {
        return;
    }
    jobject paint = ab_stroke_paint(env, c, width, cap, join, argb);
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_path, path, paint);
}

/*
 * Soft shadow.
 *
 * A hardware-accelerated Canvas ignores Paint.setShadowLayer()/setMaskFilter() for shape
 * drawing (they only apply to text), so the shadow is approximated by compositing a few
 * progressively larger, fainter rounded rects — the classic "poor man's gaussian". The
 * result is resolution independent, allocation free (one reused Paint) and visually close
 * to SwiftUI's default shadow for blur radii up to ~30 dp.
 */
void ab_draw_shadow_round_rect(ABCanvas *c, float l, float t, float r, float b, float radius,
                               float dx, float dy, float blur, uint32_t argb) {
    if (!c) {
        return;
    }
    float alpha = (float)((argb >> 24) & 0xFFu) / 255.0f;
    if (alpha <= 0.0f || r <= l || b <= t) {
        return;
    }
    JNIEnv *env = c->env;
    ABIds *ids = c->ids;
    jobject paint = c->scratch->shadow_paint;
    (*env)->CallVoidMethod(env, paint, ids->paint_set_anti_alias, JNI_TRUE);

    float spread_max = blur > 0.0f ? blur * 0.5f : 0.0f;
    if (spread_max <= 0.05f) {
        ab_fill_round_rect(c, l + dx, t + dy, r + dx, b + dy, radius, argb);
        return;
    }

    const int layers = 6;
    uint32_t rgb = argb & 0x00FFFFFFu;
    for (int i = 0; i < layers; i++) {
        float f = (float)i / (float)(layers - 1); /* 0 = outermost */
        float spread = spread_max * (1.0f - f);
        float weight = 1.0f - f;
        int a = (int)(255.0f * alpha * weight / (float)layers * 2.4f);
        if (a <= 0) {
            a = 1;
        }
        if (a > 255) {
            a = 255;
        }
        uint32_t color = rgb | ((uint32_t)a << 24);
        ab_paint_color(env, paint, ids, color);
        (*env)->CallVoidMethod(env, c->canvas, ids->canvas_draw_round_rect, l - spread + dx,
                               t - spread + dy, r + spread + dx, b + spread + dy,
                               radius + spread, radius + spread, paint);
    }
}

/* Allocate/reuse the int[] + float[] arrays handed to LinearGradient. */
static jintArray ab_gradient_colors(JNIEnv *env, ABScratch *s, const uint32_t *colors, int32_t count) {
    if (s->gradient_capacity < count) {
        if (s->gradient_colors) {
            (*env)->DeleteGlobalRef(env, s->gradient_colors);
            s->gradient_colors = NULL;
        }
        jintArray local = (*env)->NewIntArray(env, count);
        if (!local) {
            return NULL;
        }
        s->gradient_colors = (jintArray)(*env)->NewGlobalRef(env, local);
        (*env)->DeleteLocalRef(env, local);
    }
    if (!s->gradient_colors) {
        return NULL;
    }
    jint *c = (jint *)malloc(sizeof(jint) * (size_t)count);
    if (!c) {
        return NULL;
    }
    for (int32_t i = 0; i < count; i++) {
        c[i] = (jint)colors[i];
    }
    (*env)->SetIntArrayRegion(env, s->gradient_colors, 0, count, c);
    free(c);
    return s->gradient_colors;
}

static jfloatArray ab_gradient_stops(JNIEnv *env, ABScratch *s, const float *stops, int32_t count) {
    if (s->gradient_capacity < count) {
        if (s->gradient_stops) {
            (*env)->DeleteGlobalRef(env, s->gradient_stops);
            s->gradient_stops = NULL;
        }
        jfloatArray local = (*env)->NewFloatArray(env, count);
        if (!local) {
            return NULL;
        }
        s->gradient_stops = (jfloatArray)(*env)->NewGlobalRef(env, local);
        (*env)->DeleteLocalRef(env, local);
        s->gradient_capacity = count;
    }
    if (!s->gradient_stops) {
        return NULL;
    }
    if (stops) {
        (*env)->SetFloatArrayRegion(env, s->gradient_stops, 0, count, stops);
    }
    return s->gradient_stops;
}

static jobject ab_linear_gradient(JNIEnv *env, ABCanvas *c, float x0, float y0, float x1, float y1,
                                  const uint32_t *colors, const float *stops, int32_t count) {
    if (!colors || count < 2) {
        return NULL;
    }
    jintArray jcolors = ab_gradient_colors(env, c->scratch, colors, count);
    jfloatArray jstops = ab_gradient_stops(env, c->scratch, stops, count);
    if (!jcolors) {
        return NULL;
    }
    /* Local ref: the caller draws immediately, then drops it. Living inside nativeDraw's
     * PushLocalFrame keeps this allocation-free across frames. */
    return (*env)->NewObject(env, g_cls.linear_gradient, c->ids->linear_gradient_ctor, x0, y0, x1,
                             y1, jcolors, jstops, g_cls.shader_tile_clamp);
}

static void ab_fill_gradient(ABCanvas *c, jobject paint, float l, float t, float r, float b,
                             float radius, jobject shader) {
    JNIEnv *env = c->env;
    (*env)->CallObjectMethod(env, paint, c->ids->paint_set_shader, shader);
    if (radius > 0.0f) {
        (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_round_rect, l, t, r, b, radius,
                               radius, paint);
    } else {
        (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_rect, l, t, r, b, paint);
    }
    (*env)->CallObjectMethod(env, paint, c->ids->paint_set_shader, NULL);
    (*env)->DeleteLocalRef(env, shader);
}

void ab_fill_linear_gradient_rect(ABCanvas *c, float l, float t, float r, float b, float x0,
                                  float y0, float x1, float y1, const uint32_t *colors,
                                  const float *stops, int32_t count) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject shader = ab_linear_gradient(env, c, x0, y0, x1, y1, colors, stops, count);
    if (!shader) {
        if (colors && count >= 1) {
            ab_fill_rect(c, l, t, r, b, colors[0]);
        }
        return;
    }
    ab_fill_gradient(c, c->scratch->gradient_paint, l, t, r, b, 0.0f, shader);
}

void ab_fill_linear_gradient_round_rect(ABCanvas *c, float l, float t, float r, float b,
                                        float radius, float x0, float y0, float x1, float y1,
                                        const uint32_t *colors, const float *stops, int32_t count) {
    if (!c) {
        return;
    }
    JNIEnv *env = c->env;
    jobject shader = ab_linear_gradient(env, c, x0, y0, x1, y1, colors, stops, count);
    if (!shader) {
        if (colors && count >= 1) {
            ab_fill_round_rect(c, l, t, r, b, radius, colors[0]);
        }
        return;
    }
    ab_fill_gradient(c, c->scratch->gradient_paint, l, t, r, b, radius, shader);
}

void ab_draw_text(ABCanvas *c, const char *utf8, int32_t len, float x, float baseline_y, float size,
                  int32_t weight, int32_t italic, uint32_t color, float letter_spacing) {
    if (!c || !utf8 || len == 0 || size <= 0.0f) {
        return;
    }
    JNIEnv *env = c->env;
    jobject paint = ab_text_paint(env, c, size, weight, italic,
                                  ab_letter_spacing_em(letter_spacing, size));
    ab_paint_color(env, paint, c->ids, color);
    jstring text = ab_new_string(env, utf8, len);
    if (!text) {
        return;
    }
    (*env)->CallVoidMethod(env, c->canvas, c->ids->canvas_draw_text, text, x, baseline_y, paint);
    (*env)->DeleteLocalRef(env, text);
}

float ab_measure_text(ABCanvas *c, const char *utf8, int32_t len, float size, int32_t weight,
                      int32_t italic, float letter_spacing) {
    if (!c || !utf8 || len == 0 || size <= 0.0f) {
        return 0.0f;
    }
    JNIEnv *env = c->env;
    jobject paint = ab_text_paint(env, c, size, weight, italic,
                                  ab_letter_spacing_em(letter_spacing, size));
    jstring text = ab_new_string(env, utf8, len);
    if (!text) {
        return 0.0f;
    }
    jfloat width = (*env)->CallFloatMethod(env, paint, c->ids->paint_measure_text, text);
    (*env)->DeleteLocalRef(env, text);
    if (ab_clear_exception(env)) {
        return 0.0f;
    }
    return (float)width;
}

void ab_font_metrics(ABCanvas *c, float size, int32_t weight, int32_t italic, float *ascent,
                     float *descent, float *leading) {
    if (ascent) {
        *ascent = 0.0f;
    }
    if (descent) {
        *descent = 0.0f;
    }
    if (leading) {
        *leading = 0.0f;
    }
    if (!c || size <= 0.0f) {
        return;
    }
    JNIEnv *env = c->env;
    ABIds *ids = c->ids;
    jobject paint = ab_text_paint(env, c, size, weight, italic, 0.0f);
    jobject metrics = c->scratch->font_metrics;
    (*env)->CallFloatMethod(env, paint, ids->paint_get_font_metrics, metrics);
    if (ab_clear_exception(env)) {
        return;
    }
    if (ascent) {
        *ascent = (float)(*env)->GetFloatField(env, metrics, ids->font_metrics_ascent);
    }
    if (descent) {
        *descent = (float)(*env)->GetFloatField(env, metrics, ids->font_metrics_descent);
    }
    if (leading) {
        *leading = (float)(*env)->GetFloatField(env, metrics, ids->font_metrics_leading);
    }
}

/* ──────────────────────────────────────────────────────────────────────────────
 * 12. Utilities.
 * ────────────────────────────────────────────────────────────────────────────── */
void ab_invalidate(ABRuntime *rt) {
    if (!rt || !rt->view || !rt->post_invalidate) {
        return;
    }
    JNIEnv *env = ab_env();
    if (!env) {
        return;
    }
    /* postInvalidate() is thread safe and does not throw. */
    (*env)->CallVoidMethod(env, rt->view, rt->post_invalidate);
    ab_clear_exception(env);
}

double ab_seconds_since_boot(void) {
    JNIEnv *env = ab_env();
    if (env && g_cls.system_clock && t_ids.system_clock_uptime_millis) {
        jlong ms = (*env)->CallStaticLongMethod(env, g_cls.system_clock,
                                               t_ids.system_clock_uptime_millis);
        if (!ab_clear_exception(env)) {
            return (double)ms / 1000.0;
        }
    }
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
    }
    return 0.0;
}

float ab_density(ABRuntime *rt) {
    if (!rt || rt->density <= 0.0f) {
        return 1.0f;
    }
    return rt->density;
}

bool ab_is_dark_mode(ABRuntime *rt) {
    if (!rt) {
        return false;
    }
    JNIEnv *env = ab_env();
    if (env && rt->view_get_resources && rt->resources_get_configuration) {
        jobject resources = (*env)->CallObjectMethod(env, rt->view, rt->view_get_resources);
        if (resources && !ab_clear_exception(env)) {
            jobject config =
                (*env)->CallObjectMethod(env, resources, rt->resources_get_configuration);
            if (config) {
                jint ui_mode = (*env)->GetIntField(env, config, rt->configuration_ui_mode);
                rt->dark = ((ui_mode & 0x30) == 0x20);
                (*env)->DeleteLocalRef(env, config);
            }
            (*env)->DeleteLocalRef(env, resources);
        }
        ab_clear_exception(env);
    }
    return rt->dark;
}
