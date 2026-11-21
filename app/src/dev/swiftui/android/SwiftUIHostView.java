/*
 * SwiftUIHostView — the single Android View that hosts the entire SwiftUI tree.
 *
 * The View owns exactly one native runtime handle (created once in the constructor, destroyed
 * exactly once by destroyNativeHandle()). Everything that crosses into native code is in dp:
 * the View scales the Canvas by the display density before drawing, so the whole Swift/SwiftUI
 * layer never sees a physical pixel.
 *
 * Contract with Sources/AndroidBridge/AndroidBridge.c (all methods are static natives, so the
 * JNI names are Java_dev_swiftui_android_SwiftUIHostView_nativeXxx):
 *
 *   nativeCreate(view)                          -> long handle
 *   nativeResize(h, wPx, hPx, density, st, sb, sl, sr)      (insets in dp)
 *   nativeDraw(h, canvas, wDp, hDp, density)
 *   nativeTouch(h, phase, xDp, yDp)             -> consumed
 *   nativeKey(h, action, keyCode)               -> consumed
 *   nativeLifecycle(h, event)                   event: 0 create 1 resume 2 pause 3 destroy
 *   nativeConfiguration(h)                      density / dark-mode changed
 *   nativeLowMemory(h)
 *   nativeDestroy(h)
 */
package dev.swiftui.android;

import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Canvas;
import android.os.Build;
import android.util.AttributeSet;
import android.view.DisplayCutout;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowInsets;

public class SwiftUIHostView extends View {

    /* Keep in sync with AndroidBridge.h / AndroidBridge.c. */
    public static final int TOUCH_DOWN = 0;
    public static final int TOUCH_MOVE = 1;
    public static final int TOUCH_UP = 2;
    public static final int TOUCH_CANCEL = 3;

    public static final int LIFECYCLE_CREATE = 0;
    public static final int LIFECYCLE_RESUME = 1;
    public static final int LIFECYCLE_PAUSE = 2;
    public static final int LIFECYCLE_DESTROY = 3;

    static {
        // The native runtime lives in the Swift product's shared object, which the packaging
        // script installs as libswiftui_app.so.
        System.loadLibrary("swiftui_app");
    }

    private static native long nativeCreate(SwiftUIHostView view);

    private static native void nativeResize(long handle, int widthPx, int heightPx, float density,
            float safeTopDp, float safeBottomDp, float safeLeftDp, float safeRightDp);

    private static native void nativeDraw(long handle, Canvas canvas, float widthDp, float heightDp,
            float density);

    private static native boolean nativeTouch(long handle, int phase, float xDp, float yDp);

    private static native boolean nativeKey(long handle, int action, int keyCode);

    private static native void nativeLifecycle(long handle, int event);

    private static native void nativeConfiguration(long handle);

    private static native void nativeLowMemory(long handle);

    private static native void nativeDestroy(long handle);

    /** Native runtime handle; 0 means "no runtime" (create failed or already destroyed). */
    private long handle;
    /** Set by destroyNativeHandle(); after this no native call is ever made again. */
    private boolean destroyed;
    private boolean attachedToWindow;
    private boolean windowVisible;
    private int lastLifecycleEvent = -1;

    /** Device pixel ratio; refreshed on every layout / configuration change. */
    private float density = 1.0f;
    /** Safe-area insets in pixels (system bars union display cutout). */
    private int safeTopPx;
    private int safeBottomPx;
    private int safeLeftPx;
    private int safeRightPx;
    /** True once onApplyWindowInsets delivered real values. */
    private boolean hasInsets;

    public SwiftUIHostView(Context context) {
        this(context, null);
    }

    public SwiftUIHostView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    @SuppressWarnings("this-escape") // standard View constructor: mutating own setters is safe
    public SwiftUIHostView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);

        setWillNotDraw(false);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setClickable(true);
        setSaveEnabled(false);

        float d = getResources().getDisplayMetrics().density;
        if (d > 0.0f) {
            density = d;
        }
        handle = nativeCreate(this);
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * Layout / insets
     * ────────────────────────────────────────────────────────────────────────── */

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (destroyed) {
            return;
        }
        attachedToWindow = true;
        emitLifecycle(LIFECYCLE_CREATE);
        requestFocus();
        requestApplyInsets();
        if (windowVisible) {
            emitLifecycle(LIFECYCLE_RESUME);
        }
        pushSize();
    }

    @Override
    protected void onDetachedFromWindow() {
        attachedToWindow = false;
        // The window is gone: pause the SwiftUI runtime. The final LIFECYCLE_DESTROY arrives
        // from nativeDestroy() (Swift side sees exactly one create and one destroy).
        emitLifecycle(LIFECYCLE_PAUSE);
        super.onDetachedFromWindow();
    }

    @Override
    protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        windowVisible = visibility == VISIBLE;
        if (!attachedToWindow) {
            return;
        }
        emitLifecycle(windowVisible ? LIFECYCLE_RESUME : LIFECYCLE_PAUSE);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        pushSize();
    }

    @SuppressWarnings("deprecation") // getSystemWindowInset* is the only API below API 30
    @Override
    public WindowInsets onApplyWindowInsets(WindowInsets insets) {
        int top;
        int bottom;
        int left;
        int right;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            int[] bars = Insets30.systemBarsAndCutout(insets);
            top = bars[0];
            bottom = bars[1];
            left = bars[2];
            right = bars[3];
        } else {
            top = insets.getSystemWindowInsetTop();
            bottom = insets.getSystemWindowInsetBottom();
            left = insets.getSystemWindowInsetLeft();
            right = insets.getSystemWindowInsetRight();
            DisplayCutout cutout = insets.getDisplayCutout();
            if (cutout != null) {
                top = Math.max(top, cutout.getSafeInsetTop());
                bottom = Math.max(bottom, cutout.getSafeInsetBottom());
                left = Math.max(left, cutout.getSafeInsetLeft());
                right = Math.max(right, cutout.getSafeInsetRight());
            }
        }
        if (top != safeTopPx || bottom != safeBottomPx || left != safeLeftPx
                || right != safeRightPx || !hasInsets) {
            safeTopPx = top;
            safeBottomPx = bottom;
            safeLeftPx = left;
            safeRightPx = right;
            hasInsets = true;
            pushSize();
        }
        // The SwiftUI tree lays itself out inside the safe area, so the insets are not consumed.
        return insets;
    }

    /** Push the current size, density and safe-area insets to the native runtime. */
    private void pushSize() {
        long h = handle;
        if (h == 0 || destroyed) {
            return;
        }
        int wPx = getWidth();
        int hPx = getHeight();
        if (wPx <= 0 || hPx <= 0) {
            return;
        }
        float d = getResources().getDisplayMetrics().density;
        if (d <= 0.0f) {
            d = 1.0f;
        }
        density = d;
        nativeResize(h, wPx, hPx, d, safeTopPx / d, safeBottomPx / d, safeLeftPx / d,
                safeRightPx / d);
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * Drawing
     * ────────────────────────────────────────────────────────────────────────── */

    @Override
    protected void onDraw(Canvas canvas) {
        long h = handle;
        if (h == 0 || destroyed) {
            return;
        }
        float d = density;
        if (d <= 0.0f) {
            return;
        }
        float widthDp = getWidth() / d;
        float heightDp = getHeight() / d;
        int save = canvas.save();
        // The bridge and the whole SwiftUI layer work in dp.
        canvas.scale(d, d);
        try {
            nativeDraw(h, canvas, widthDp, heightDp, d);
        } finally {
            canvas.restoreToCount(save);
        }
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * Input
     * ────────────────────────────────────────────────────────────────────────── */

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        long h = handle;
        if (h == 0 || destroyed) {
            return false;
        }
        float d = density > 0.0f ? density : 1.0f;
        int action = event.getActionMasked();
        int phase;
        switch (action) {
            case MotionEvent.ACTION_DOWN:
                phase = TOUCH_DOWN;
                break;
            case MotionEvent.ACTION_MOVE:
                phase = TOUCH_MOVE;
                break;
            case MotionEvent.ACTION_UP:
                phase = TOUCH_UP;
                break;
            case MotionEvent.ACTION_CANCEL:
                phase = TOUCH_CANCEL;
                break;
            case MotionEvent.ACTION_POINTER_DOWN:
            case MotionEvent.ACTION_POINTER_UP:
                // The bridge is single-pointer: report an extra MOVE at the primary pointer
                // position so the recogniser keeps tracking it.
                phase = TOUCH_MOVE;
                break;
            default:
                return false;
        }
        // Single-pointer bridge: always report the primary pointer (index 0).
        float xDp = event.getX(0) / d;
        float yDp = event.getY(0) / d;
        boolean consumed = nativeTouch(h, phase, xDp, yDp);
        // Keep receiving the rest of the gesture: a DOWN that nobody "consumed" yet still
        // belongs to this view (hit testing happens inside SwiftUI).
        return consumed || phase == TOUCH_DOWN || phase == TOUCH_MOVE;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            // BACK is owned by handleBackPressed() so it works identically with the legacy
            // Activity.onBackPressed path and the API 33+ OnBackInvokedCallback path.
            return false;
        }
        if (forwardKey(0, keyCode)) {
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            return false;
        }
        if (forwardKey(1, keyCode)) {
            return true;
        }
        return super.onKeyUp(keyCode, event);
    }

    private boolean forwardKey(int action, int keyCode) {
        long h = handle;
        if (h == 0 || destroyed) {
            return false;
        }
        return nativeKey(h, action, keyCode);
    }

    /**
     * Forwards a BACK gesture/button to the SwiftUI tree.
     *
     * @return true when SwiftUI consumed it (navigation popped, sheet dismissed, ...); the
     *         host then does nothing. false means the activity should finish normally.
     */
    public boolean handleBackPressed() {
        long h = handle;
        if (h == 0 || destroyed) {
            return false;
        }
        boolean down = nativeKey(h, 0, KeyEvent.KEYCODE_BACK);
        boolean up = nativeKey(h, 1, KeyEvent.KEYCODE_BACK);
        return down || up;
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * Lifecycle / configuration, driven by MainActivity
     * ────────────────────────────────────────────────────────────────────────── */

    public void onHostResume() {
        if (attachedToWindow && !destroyed) {
            emitLifecycle(LIFECYCLE_RESUME);
        }
    }

    public void onHostPause() {
        if (!destroyed) {
            emitLifecycle(LIFECYCLE_PAUSE);
        }
    }

    public void onHostLowMemory() {
        long h = handle;
        if (h == 0 || destroyed) {
            return;
        }
        nativeLowMemory(h);
    }

    /** Re-read density / night mode after onConfigurationChanged and re-layout. */
    public void refreshConfiguration() {
        long h = handle;
        if (h == 0 || destroyed) {
            return;
        }
        float d = getResources().getDisplayMetrics().density;
        if (d > 0.0f) {
            density = d;
        }
        nativeConfiguration(h);
        pushSize();
        requestApplyInsets();
        invalidate();
    }

    /** True when the platform is in night mode (also mirrored in Swift via ab_is_dark_mode). */
    public boolean isNightMode() {
        int mode = getResources().getConfiguration().uiMode;
        return (mode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
    }

    private void emitLifecycle(int event) {
        long h = handle;
        if (h == 0 || destroyed || event == lastLifecycleEvent) {
            return;
        }
        lastLifecycleEvent = event;
        nativeLifecycle(h, event);
    }

    /** Tears the native runtime down. Idempotent: exactly one nativeDestroy() ever happens. */
    public void destroyNativeHandle() {
        if (destroyed) {
            return;
        }
        destroyed = true;
        lastLifecycleEvent = LIFECYCLE_DESTROY;
        long h = handle;
        handle = 0;
        if (h != 0) {
            nativeDestroy(h);
        }
    }

    /** For diagnostics only; never call native with a stale value. */
    public long nativeHandle() {
        return handle;
    }

    /**
     * API 30+ window-inset reader.
     *
     * Isolated in its own class (loaded only when SDK_INT >= 30) so android.graphics.Insets
     * and WindowInsets.Type are never resolved on API 28–29.
     */
    private static final class Insets30 {
        static int[] systemBarsAndCutout(WindowInsets insets) {
            android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            return new int[] {bars.top, bars.bottom, bars.left, bars.right};
        }
    }
}
