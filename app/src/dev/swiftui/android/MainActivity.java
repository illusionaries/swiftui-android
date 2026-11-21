/*
 * MainActivity — the single launcher Activity hosting SwiftUIHostView.
 *
 * Plain framework APIs only (no AppCompat, no Compose, no Kotlin). The Activity is
 * responsible for:
 *   • edge-to-edge layout (decorFitsSystemWindows=false on API 30+, layout flags below),
 *   • transparent system bars with light/dark icons derived from the night mode,
 *   • a window background matching the SwiftUI root background (avoids a white flash),
 *   • surviving orientation / uiMode / density changes without recreating the process
 *     (declared in the manifest via android:configChanges),
 *   • BACK: OnBackInvokedCallback on API 33+, Activity.onBackPressed below that,
 *   • forwarding lifecycle / low-memory to the SwiftUI runtime and destroying it exactly once.
 */
package dev.swiftui.android;

import android.app.Activity;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;

public final class MainActivity extends Activity {

    private SwiftUIHostView hostView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        configureWindow();

        hostView = new SwiftUIHostView(this);
        setContentView(hostView);

        registerBackCallback();

        // The window has no decor / no InsetsController yet inside onCreate, so window-bar
        // appearance must wait until after the view is attached. View.post() runs after
        // dispatchAttachedToWindow(), i.e. exactly when the InsetsController becomes valid.
        hostView.post(this::applySystemBarAppearance);
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * Window / system bars
     * ────────────────────────────────────────────────────────────────────────── */

    @SuppressWarnings("deprecation") // legacy system-bar APIs are still needed below API 30
    private void configureWindow() {
        Window window = getWindow();

        // Match the SwiftUI root background so the first frame does not flash a different colour.
        window.setBackgroundDrawable(new ColorDrawable(getColor(R.color.window_background)));
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
        window.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS
                | WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // API 30+: draw behind the system bars, let the View handle the insets.
            window.setDecorFitsSystemWindows(false);
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS);
            View decor = window.getDecorView();
            if (decor != null) {
                decor.setSystemUiVisibility(
                        View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
            }
        }

        window.setStatusBarColor(Color.TRANSPARENT);
        window.setNavigationBarColor(Color.TRANSPARENT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.setNavigationBarContrastEnforced(false);
        }

        // NOTE: bar *appearance* (icon colour) is intentionally NOT applied here: in onCreate
        // the decor view is not attached yet and Window.getInsetsController() NPEs inside the
        // framework. It is applied from post-attach points instead (onWindowFocusChanged,
        // onResume, onConfigurationChanged and the post()ed call from onCreate).
    }

    /**
     * Light icons on a dark background and vice versa, following the current night mode.
     *
     * Safe to call at any time: it never touches the window's InsetsController before the
     * window is attached (that is what made onCreate crash with an NPE), and returns false
     * when the call had to be skipped so a later lifecycle point can retry.
     */
    @SuppressWarnings("deprecation") // View.SYSTEM_UI_FLAG_* is the only API below API 30
    private boolean applySystemBarAppearance() {
        Window window = getWindow();
        if (window == null) {
            return false;
        }
        boolean dark = isNightMode();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Bars30.apply(window, dark);
        }
        View decor = window.getDecorView();
        if (decor == null) {
            return false;
        }
        int flags = decor.getSystemUiVisibility();
        int light = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        decor.setSystemUiVisibility(dark ? (flags & ~light) : (flags | light));
        return true;
    }

    private boolean isNightMode() {
        int mode = getResources().getConfiguration().uiMode;
        return (mode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * BACK
     * ────────────────────────────────────────────────────────────────────────── */

    @SuppressWarnings("deprecation") // onBackPressed is still the path below API 33
    @Override
    public void onBackPressed() {
        if (hostView != null && hostView.handleBackPressed()) {
            return;
        }
        super.onBackPressed();
    }

    private void registerBackCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return; // legacy BACK key path: onKeyUp -> onBackPressed() -> handleBackPressed()
        }
        BackInvoked.register(this, () -> {
            if (hostView != null && hostView.handleBackPressed()) {
                return;
            }
            finish();
        });
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * Lifecycle / configuration
     * ────────────────────────────────────────────────────────────────────────── */

    @Override
    protected void onResume() {
        super.onResume();
        if (hostView != null) {
            hostView.onHostResume();
        }
        // May still be too early (the window is attached during handleResumeActivity), in
        // which case onWindowFocusChanged() applies it a moment later.
        applySystemBarAppearance();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            // First reliable post-attach point: the InsetsController exists from here on.
            applySystemBarAppearance();
        }
    }

    @Override
    protected void onPause() {
        if (hostView != null) {
            hostView.onHostPause();
        }
        super.onPause();
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // The manifest declares uiMode|density|orientation|... so the process (and the SwiftUI
        // runtime) survives: refresh the window and let the View re-push density + insets.
        configureWindow();
        applySystemBarAppearance();
        if (hostView != null) {
            hostView.refreshConfiguration();
        }
    }

    @Override
    public void onLowMemory() {
        super.onLowMemory();
        if (hostView != null) {
            hostView.onHostLowMemory();
        }
    }

    @Override
    protected void onDestroy() {
        if (hostView != null) {
            hostView.destroyNativeHandle();
            hostView = null;
        }
        super.onDestroy();
    }

    /**
     * API 33+ back dispatch.
     *
     * Isolated in its own class so the android.window.* types are only resolved when the
     * class is actually loaded (i.e. only on API 33+); on API 28–32 the VM never touches it.
     */
    private static final class BackInvoked {
        static void register(Activity activity, Runnable onBack) {
            android.window.OnBackInvokedCallback callback =
                    new android.window.OnBackInvokedCallback() {
                        @Override
                        public void onBackInvoked() {
                            onBack.run();
                        }
                    };
            activity.getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback);
        }
    }

    /**
     * API 30+ system-bar appearance.
     *
     * Isolated in its own class (loaded only when SDK_INT >= 30) so android.view
     * .WindowInsetsController is never resolved on API 28–29.
     */
    private static final class Bars30 {
        /** @return true when the appearance was applied (window attached), false to retry later. */
        static boolean apply(Window window, boolean dark) {
            View decor = window.getDecorView();
            if (decor == null) {
                return false;
            }
            // View.getWindowInsetsController() (not Window.getInsetsController()): it is
            // null-safe and simply returns null while the view is not attached, whereas the
            // Window variant dereferences a possibly-null decor and throws NPE in onCreate.
            android.view.WindowInsetsController controller = decor.getWindowInsetsController();
            if (controller == null) {
                return false;
            }
            int mask = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                    | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            controller.setSystemBarsAppearance(dark ? 0 : mask, mask);
            return true;
        }
    }
}
