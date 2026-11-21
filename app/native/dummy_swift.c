/*
 * dummy_swift.c — packaging stand-in for the real SwiftUIAndroidApp shared object.
 *
 * Packaging (aapt2 -> javac -> d8 -> zip -> zipalign -> apksigner) must be verifiable before
 * the Swift toolchain / Swift SDK for Android is available. In --dummy mode
 * scripts/build-apk.sh compiles this file into libswiftui_app.so instead of running SwiftPM,
 * so every APK-level check (dex, native libs, alignment, signature) can run today.
 *
 * It defines exactly the JNI entry points the Java host calls and does nothing:
 * nativeCreate() returns 0, so the Java view never calls into the runtime.
 *
 * This file is NOT part of the SwiftPM package (it lives outside Sources/).
 */
#include <jni.h>
#include <stdint.h>

#define AB_UNUSED(x) (void)(x)

/* Marker readable with `strings`/`llvm-nm` to prove which .so was packaged. */
__attribute__((visibility("default"))) const char *swiftui_android_dummy_stub(void) {
    return "swiftui-android-dummy-stub";
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    AB_UNUSED(vm);
    AB_UNUSED(reserved);
    return JNI_VERSION_1_6;
}

JNIEXPORT jlong JNICALL
Java_dev_swiftui_android_SwiftUIHostView_nativeCreate(JNIEnv *env, jclass clazz, jobject view) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(view);
    return 0;
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeResize(
    JNIEnv *env, jclass clazz, jlong handle, jint width_px, jint height_px, jfloat density,
    jfloat safe_top, jfloat safe_bottom, jfloat safe_left, jfloat safe_right) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
    AB_UNUSED(width_px);
    AB_UNUSED(height_px);
    AB_UNUSED(density);
    AB_UNUSED(safe_top);
    AB_UNUSED(safe_bottom);
    AB_UNUSED(safe_left);
    AB_UNUSED(safe_right);
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeConfiguration(
    JNIEnv *env, jclass clazz, jlong handle) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeDraw(
    JNIEnv *env, jclass clazz, jlong handle, jobject canvas, jfloat width_dp, jfloat height_dp,
    jfloat density) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
    AB_UNUSED(canvas);
    AB_UNUSED(width_dp);
    AB_UNUSED(height_dp);
    AB_UNUSED(density);
}

JNIEXPORT jboolean JNICALL
Java_dev_swiftui_android_SwiftUIHostView_nativeTouch(JNIEnv *env, jclass clazz, jlong handle,
                                                    jint phase, jfloat x_dp, jfloat y_dp) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
    AB_UNUSED(phase);
    AB_UNUSED(x_dp);
    AB_UNUSED(y_dp);
    return JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeKey(
    JNIEnv *env, jclass clazz, jlong handle, jint action, jint key_code) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
    AB_UNUSED(action);
    AB_UNUSED(key_code);
    return JNI_FALSE;
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeLifecycle(
    JNIEnv *env, jclass clazz, jlong handle, jint event) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
    AB_UNUSED(event);
}

JNIEXPORT void JNICALL Java_dev_swiftui_android_SwiftUIHostView_nativeLowMemory(
    JNIEnv *env, jclass clazz, jlong handle) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
}

JNIEXPORT void JNICALL
Java_dev_swiftui_android_SwiftUIHostView_nativeDestroy(JNIEnv *env, jclass clazz, jlong handle) {
    AB_UNUSED(env);
    AB_UNUSED(clazz);
    AB_UNUSED(handle);
}
