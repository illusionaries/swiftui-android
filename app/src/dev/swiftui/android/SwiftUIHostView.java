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
 *
 * Text input has its own natives, implemented in Swift (see the JNI section of
 * Sources/SwiftUIAndroid/AndroidRuntime.swift); the View polls them, it is not pushed to:
 *
 *   nativeTextInputCommand(h) -> int            0 none 1 begin 2 move 3 end
 *   nativeTextInputSlot(h) -> int
 *   nativeTextInputFrame(h, part) -> float      part: 0 left 1 top 2 width 3 height (dp)
 *   nativeTextInputTextLength(h) -> int         UTF-16 code units
 *   nativeTextInputTextChunk(h, unitOffset) -> long   4 code units packed per long
 *   nativeTextInputAck(h)                       the pending request has been consumed
 *   nativeTextChangedBegin(h, length)           whole-text snapshot starts
 *   nativeTextChangedChunk(h, packed)           one chunk of it
 *   nativeTextChangedCommit(h)                  snapshot complete
 *   nativeTextEnded(h, reason)                  the editor closed on its own
 */
package dev.swiftui.android;

import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Canvas;
import android.os.Build;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.AttributeSet;
import android.util.Log;
import android.util.TypedValue;
import android.view.DisplayCutout;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;

/**
 * A {@link FrameLayout} rather than a plain View only because of the text editor: the IME needs a
 * real descendant to own the session, and a child's coordinates are already this View's dp space.
 * Nothing else is added to the tree, and the drawing is unchanged ({@code onDraw} still paints the
 * whole SwiftUI tree; the invisible child is drawn after it).
 */
public class SwiftUIHostView extends FrameLayout {

    /* Keep in sync with AndroidBridge.h / AndroidBridge.c. */
    public static final int TOUCH_DOWN = 0;
    public static final int TOUCH_MOVE = 1;
    public static final int TOUCH_UP = 2;
    public static final int TOUCH_CANCEL = 3;

    public static final int LIFECYCLE_CREATE = 0;
    public static final int LIFECYCLE_RESUME = 1;
    public static final int LIFECYCLE_PAUSE = 2;
    public static final int LIFECYCLE_DESTROY = 3;

    /* Text input request kinds, returned by nativeTextInputCommand (see AndroidTextInput). */
    public static final int TEXT_INPUT_NONE = 0;
    public static final int TEXT_INPUT_BEGIN = 1;
    public static final int TEXT_INPUT_FRAME = 2;
    public static final int TEXT_INPUT_END = 3;

    /* Components of nativeTextInputFrame. */
    public static final int TEXT_INPUT_LEFT = 0;
    public static final int TEXT_INPUT_TOP = 1;
    public static final int TEXT_INPUT_WIDTH = 2;
    public static final int TEXT_INPUT_HEIGHT = 3;

    /* Why the editor closed; kept for logcat and for a future onEditingChanged-style report. */
    public static final int TEXT_INPUT_DONE = 0;
    public static final int TEXT_INPUT_CANCELLED = 1;
    public static final int TEXT_INPUT_FOCUS_LOST = 2;
    public static final int TEXT_INPUT_DESTROYED = 3;

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

    /* Text input (IME). Implemented in Swift, see the JNI section of AndroidRuntime.swift. */
    private static native int nativeTextInputCommand(long handle);

    private static native int nativeTextInputSlot(long handle);

    private static native float nativeTextInputFrame(long handle, int component);

    private static native int nativeTextInputTextLength(long handle);

    private static native long nativeTextInputTextChunk(long handle, int unitOffset);

    private static native void nativeTextInputAck(long handle);

    private static native void nativeTextChangedBegin(long handle, int length);

    private static native void nativeTextChangedChunk(long handle, long packed);

    private static native void nativeTextChangedCommit(long handle);

    private static native void nativeTextEnded(long handle, int reason);

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

    /** The transparent platform editor while a SwiftUI text control has focus, else null. */
    private EditText textInput;
    /**
     * Set once a text-input native failed to resolve. The whole feature is then skipped instead
     * of throwing on every frame: the port keeps rendering, only typing is unavailable.
     */
    private boolean textInputUnavailable;
    /** Last dp rectangle handed to nativeTextInput* , kept so a density change can re-apply it. */
    private float textInputLeftDp;
    private float textInputTopDp;
    private float textInputWidthDp;
    private float textInputHeightDp;

    /** Logcat tag shared with scripts/device-test.sh and the C bridge diagnostics. */
    private static final String LOG_TAG = "SwiftUIBridge";
    /** Last safe-area values handed to nativeResize, so we log each change once. */
    private int loggedTopPx = -1;
    private int loggedBottomPx = -1;
    private int loggedLeftPx = -1;
    private int loggedRightPx = -1;
    private boolean loggedFirstFrame;

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
        // The editor sits in pixels derived from dp, so a density change has to re-place it even
        // when the dp rectangle itself did not move.
        repositionTextInput();
        float topDp = safeTopPx / d;
        float bottomDp = safeBottomPx / d;
        float leftDp = safeLeftPx / d;
        float rightDp = safeRightPx / d;

        // Visible in `adb logcat -s SwiftUIBridge`; confirms that gesture-navigation AVDs still
        // report non-zero system-bar insets and that a rotation/inset change re-pushes them.
        if (!loggedFirstFrame || safeTopPx != loggedTopPx || safeBottomPx != loggedBottomPx
                || safeLeftPx != loggedLeftPx || safeRightPx != loggedRightPx) {
            loggedFirstFrame = true;
            loggedTopPx = safeTopPx;
            loggedBottomPx = safeBottomPx;
            loggedLeftPx = safeLeftPx;
            loggedRightPx = safeRightPx;
            Log.i(LOG_TAG, "nativeResize " + wPx + "x" + hPx + "px density=" + d
                    + " -> " + (wPx / d) + "x" + (hPx / d) + "dp"
                    + " safeArea(px)=[" + safeTopPx + "," + safeBottomPx + ","
                    + safeLeftPx + "," + safeRightPx + "]"
                    + " safeArea(dp)=[" + topDp + "," + bottomDp + "," + leftDp + ","
                    + rightDp + "]");
        }

        nativeResize(h, wPx, hPx, d, topDp, bottomDp, leftDp, rightDp);
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
        // Requests raised while rendering the previous frame are acted on before this one paints,
        // so an editor that appears or disappears does so in step with the drawing.
        syncTextInput();
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
        // A tap on a text control begins or ends editing inside nativeTouch; poll now so the
        // keyboard follows the tap in the same event rather than a frame later.
        syncTextInput();
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
            // A forwarded key can move focus (Tab-like navigation); let the editor follow.
            syncTextInput();
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
        // While a text editor is open, BACK belongs to it: the first press closes the keyboard and
        // ends the session, exactly as it does for a native EditText. Consuming it here is also
        // what keeps the activity from finishing under an open keyboard.
        if (textInput != null) {
            endTextInputFromPlatform(TEXT_INPUT_CANCELLED);
            return true;
        }
        long h = handle;
        if (h == 0 || destroyed) {
            return false;
        }
        boolean down = nativeKey(h, 0, KeyEvent.KEYCODE_BACK);
        boolean up = nativeKey(h, 1, KeyEvent.KEYCODE_BACK);
        return down || up;
    }

    /* ──────────────────────────────────────────────────────────────────────────
     * Text input (the IME overlay)
     * ──────────────────────────────────────────────────────────────────────────
     *
     * A ported SwiftUI text control needs what drawing cannot express: a caret, a selection and
     * the system IME. Those come from a real platform editor, so this View hosts a transparent
     * EditText over the drawing. SwiftUI keeps rendering the text — that is what keeps its
     * styling, and the binding, authoritative — while the EditText owns the IME session and
     * reports every change. The visible glyphs are therefore the SwiftUI ones; the keyboard is
     * Android's, unchanged.
     *
     * Swift cannot call into Java in this process (Sources/SwiftUIAndroid deliberately holds no
     * JNIEnv), so the request travels the other way: this View polls the runtime once per frame
     * and after every input event and pulls the pending request out of it. Text crosses as UTF-16
     * code units packed four to a long, because reading a String would itself need JNIEnv.
     */

    /**
     * Pull one pending request out of the SwiftUI runtime and act on it.
     *
     * This poll is also how a tap that focuses a TextField reaches this View: the tap goes to
     * nativeTouch, the SwiftUI adapter calls PortTextInput.beginEditing, and the poll at the end
     * of onTouchEvent sees the request immediately (no frame of latency). A request raised by a
     * state change instead is picked up by the poll at the start of the next onDraw.
     */
    private void syncTextInput() {
        long h = handle;
        if (h == 0 || destroyed || textInputUnavailable) {
            return;
        }
        try {
            switch (nativeTextInputCommand(h)) {
                case TEXT_INPUT_BEGIN:
                    beginTextInput(h);
                    nativeTextInputAck(h);
                    break;
                case TEXT_INPUT_FRAME:
                    applyTextInputFrame(nativeTextInputFrame(h, TEXT_INPUT_LEFT),
                            nativeTextInputFrame(h, TEXT_INPUT_TOP),
                            nativeTextInputFrame(h, TEXT_INPUT_WIDTH),
                            nativeTextInputFrame(h, TEXT_INPUT_HEIGHT));
                    nativeTextInputAck(h);
                    break;
                case TEXT_INPUT_END:
                    hideTextInput();
                    nativeTextInputAck(h);
                    break;
                default:
                    break;
            }
        } catch (UnsatisfiedLinkError e) {
            // A missing symbol must not take the app down: drawing keeps working without typing,
            // and one log line says exactly what happened.
            textInputUnavailable = true;
            Log.w(LOG_TAG, "text input unavailable (" + e.getMessage()
                    + "); typing is disabled, drawing is unaffected");
        }
    }

    /** Read a begin request in full, then build the editor for it. */
    private void beginTextInput(long h) {
        int slot = nativeTextInputSlot(h);
        int length = Math.max(0, nativeTextInputTextLength(h));
        StringBuilder text = new StringBuilder(length);
        for (int unit = 0; unit < length; unit += 4) {
            long packed = nativeTextInputTextChunk(h, unit);
            for (int i = 0; i < 4; i++) {
                text.append((char) ((packed >>> (16 * i)) & 0xFFFFL));
            }
        }
        // The last chunk is zero-padded to a multiple of four; the length is the truth.
        text.setLength(length);
        showTextInput(slot, text.toString(), nativeTextInputFrame(h, TEXT_INPUT_LEFT),
                nativeTextInputFrame(h, TEXT_INPUT_TOP),
                nativeTextInputFrame(h, TEXT_INPUT_WIDTH),
                nativeTextInputFrame(h, TEXT_INPUT_HEIGHT));
    }

    /** Install the platform editor over the requested dp rectangle and open the keyboard. */
    private void showTextInput(int slot, String text, float leftDp, float topDp, float widthDp,
            float heightDp) {
        // Focus moved (or the same control asked again after its editor was torn down): start
        // from a clean editor, because the old one still owns the IME until it is removed.
        hideTextInput();

        final EditText editor = new EditText(getContext());
        // SwiftUI paints the text; the editor must be neither seen nor heard from.
        editor.setAlpha(0.0f);
        editor.setCursorVisible(false);
        editor.setBackground(null);
        editor.setPadding(0, 0, 0, 0);
        editor.setSingleLine(true);
        editor.setInputType(InputType.TYPE_CLASS_TEXT);
        editor.setImeOptions(EditorInfo.IME_ACTION_DONE);
        // Explicit rather than assumed: the host is in touch mode, and only a child that is
        // focusable *in touch mode* can take focus away from it and receive the IME.
        editor.setFocusable(true);
        editor.setFocusableInTouchMode(true);
        // The text lives in SwiftUI state and in this editor, never in the view hierarchy: a
        // restored instance state would silently overwrite the binding after a rotation.
        editor.setSaveEnabled(false);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            editor.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        }
        // A plausible text size keeps the editor's internal layout (and the IME's idea of where
        // the field is) sane; none of it is ever painted at alpha 0.
        float heightPx = Math.max(1.0f, heightDp * (density > 0.0f ? density : 1.0f));
        editor.setTextSize(TypedValue.COMPLEX_UNIT_PX, Math.max(8.0f, heightPx * 0.55f));
        editor.setText(text);
        editor.setSelection(editor.getText().length());
        // Attached after seeding, so the initial text is not reported back as a user edit.
        editor.addTextChangedListener(new TextChangeRelay(this, editor));
        editor.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_DONE || actionId == EditorInfo.IME_ACTION_GO
                    || actionId == EditorInfo.IME_ACTION_SEND
                    || actionId == EditorInfo.IME_ACTION_NEXT) {
                endTextInputFromPlatform(TEXT_INPUT_DONE);
                return true;
            }
            return false;
        });
        editor.setOnFocusChangeListener((v, hasFocus) -> {
            if (!hasFocus && textInput == v) {
                // Focus left without the SwiftUI side asking for it: the session has to end, or
                // the caret would live on with no editor behind it.
                endTextInputFromPlatform(TEXT_INPUT_FOCUS_LOST);
            }
        });
        textInput = editor;
        textInputLeftDp = leftDp;
        textInputTopDp = topDp;
        textInputWidthDp = widthDp;
        textInputHeightDp = heightDp;
        addView(editor, textInputLayoutParams(leftDp, topDp, widthDp, heightDp));
        editor.requestFocus();
        editor.post(() -> {
            if (textInput == editor) {
                InputMethodManager imm = inputMethodManager();
                if (imm != null) {
                    imm.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT);
                }
            }
        });
        Log.i(LOG_TAG, "text input begin slot=" + slot + " frame(dp)=[" + leftDp + "," + topDp
                + "," + widthDp + "," + heightDp + "] length=" + text.length());
    }

    /**
     * dp -> px. The rest of this file converts the other way (divides pixels by {@code density}),
     * so the factor is the same one the Canvas is scaled with.
     */
    private FrameLayout.LayoutParams textInputLayoutParams(float leftDp, float topDp,
            float widthDp, float heightDp) {
        float d = density > 0.0f ? density : 1.0f;
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                Math.max(1, Math.round(widthDp * d)), Math.max(1, Math.round(heightDp * d)));
        // LEFT, not START: the rectangle is a physical coordinate, the same one the canvas uses.
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        lp.leftMargin = Math.max(0, Math.round(leftDp * d));
        lp.topMargin = Math.max(0, Math.round(topDp * d));
        return lp;
    }

    /** The focused control moved, or the density changed: follow it. */
    private void applyTextInputFrame(float leftDp, float topDp, float widthDp, float heightDp) {
        textInputLeftDp = leftDp;
        textInputTopDp = topDp;
        textInputWidthDp = widthDp;
        textInputHeightDp = heightDp;
        EditText editor = textInput;
        if (editor != null) {
            editor.setLayoutParams(textInputLayoutParams(leftDp, topDp, widthDp, heightDp));
        }
    }

    /** Re-apply the last dp rectangle after a density or size change (the dp values are stable). */
    private void repositionTextInput() {
        if (textInput != null) {
            applyTextInputFrame(textInputLeftDp, textInputTopDp, textInputWidthDp,
                    textInputHeightDp);
        }
    }

    /** Remove the platform editor, if any. Reports nothing to SwiftUI (see the two callers). */
    private void hideTextInput() {
        EditText editor = textInput;
        if (editor == null) {
            return;
        }
        // Detach the listeners first: removeView() takes focus away, and the focus listener would
        // otherwise report a second end for a session that is already over.
        textInput = null;
        editor.setOnFocusChangeListener(null);
        editor.setOnEditorActionListener(null);
        InputMethodManager imm = inputMethodManager();
        if (imm != null) {
            imm.hideSoftInputFromWindow(editor.getWindowToken(), 0);
        }
        removeView(editor);
        // Focus back on this View, so hardware keys reach the SwiftUI tree again.
        requestFocus();
        Log.i(LOG_TAG, "text input end");
    }

    /**
     * The editor ended the session on its own (IME action, BACK, focus loss): tear it down and
     * tell SwiftUI. The other direction — SwiftUI asking for the end — is TEXT_INPUT_END in
     * syncTextInput(), which does not call back in.
     */
    private void endTextInputFromPlatform(int reason) {
        if (textInput == null) {
            return;
        }
        hideTextInput();
        long h = handle;
        if (h == 0 || destroyed || textInputUnavailable) {
            return;
        }
        try {
            nativeTextEnded(h, reason);
        } catch (UnsatisfiedLinkError e) {
            textInputUnavailable = true;
            Log.w(LOG_TAG, "text input unavailable (" + e.getMessage()
                    + "); typing is disabled, drawing is unaffected");
        }
    }

    /**
     * Push the editor's whole text to SwiftUI as packed UTF-16 code units.
     *
     * Whole snapshots rather than deltas: the editor already holds the new text, and a delta would
     * have to be diffed on one side and re-applied on the other to reach the same state. A field
     * is short and this runs once per keystroke; the encoding costs four bytes per two characters.
     */
    private void sendTextInput(String text) {
        long h = handle;
        if (h == 0 || destroyed || textInputUnavailable) {
            return;
        }
        try {
            int length = text.length();
            nativeTextChangedBegin(h, length);
            for (int unit = 0; unit < length; unit += 4) {
                long packed = 0L;
                for (int i = 0; i < 4 && unit + i < length; i++) {
                    packed |= ((long) text.charAt(unit + i)) << (16 * i);
                }
                nativeTextChangedChunk(h, packed);
            }
            nativeTextChangedCommit(h);
        } catch (UnsatisfiedLinkError e) {
            textInputUnavailable = true;
            Log.w(LOG_TAG, "text input unavailable (" + e.getMessage()
                    + "); typing is disabled, drawing is unaffected");
        }
    }

    private InputMethodManager inputMethodManager() {
        Context context = getContext();
        return context == null
                ? null
                : (InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
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
        // The window is going away with this View: drop the editor before the runtime dies, so no
        // native call is ever made on behalf of a dead handle.
        hideTextInput();
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
     * Reports edits back to Swift.
     *
     * A static nested class that holds the host explicitly, not an anonymous inner class: javac
     * gives an inner class a synthetic `this$0` field, and the d8 in this project's build-tools
     * (8.2.2) crashes with an internal NullPointerException on any class that captures its
     * enclosing instance. Static nesting sidesteps that and costs nothing here.
     */
    private static final class TextChangeRelay implements TextWatcher {
        private final SwiftUIHostView host;
        private final EditText editor;

        TextChangeRelay(SwiftUIHostView host, EditText editor) {
            this.host = host;
            this.editor = editor;
        }

        @Override
        public void beforeTextChanged(CharSequence s, int start, int count, int after) {
        }

        @Override
        public void onTextChanged(CharSequence s, int start, int before, int count) {
        }

        @Override
        public void afterTextChanged(Editable s) {
            if (host.textInput != editor) {
                return; // a replacement editor, or one that is being torn down
            }
            host.sendTextInput(s.toString());
        }
    }

    /**
     * API 30+ window-inset reader.
     *
     * Isolated in its own class (loaded only when SDK_INT >= 30) so android.graphics.Insets
     * and WindowInsets.Type are never resolved on API 28–29.
     */
    private static final class Insets30 {
        static int[] systemBarsAndCutout(WindowInsets insets) {
            // Include the gesture area: with gesture navigation `systemBars()` reports no bottom
            // inset, so a bottom-anchored bar (a tab bar) would sit under the gesture pill.
            android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars()
                            | WindowInsets.Type.displayCutout()
                            | WindowInsets.Type.systemGestures());
            return new int[] {bars.top, bars.bottom, bars.left, bars.right};
        }
    }
}
