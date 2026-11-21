// AndroidRuntime.swift — the JNI-facing runtime for the SwiftUI port.
//
// This is the only place that knows Android exists. It exports the seven C-linkage entry
// points declared in AndroidBridge.h, owns the frame loop, and replays the engine's
// DisplayList into android.graphics.Canvas through the C bridge.
//
// Threading: every entry point is called on the Android UI thread (see DESIGN.md). The only
// call we make off-thread is ab_invalidate, which posts View.postInvalidate().

import AndroidBridge
import Foundation
import SwiftUI

// The runtime is Android-only: it exports JNI entry points and talks to the NDK-backed
// bridge. On host builds (swift test) the file compiles to nothing so the package's
// dynamic product still links.
#if os(Android)

// MARK: - Scene resolution

/// The C bridge resolves the app's exported `swiftui_app_entry` with the linker (weak symbol)
/// and hands the retained object over here. Doing the lookup there — rather than with
/// `dlsym(RTLD_DEFAULT)` here — is deliberate: on Android, a JNI library lives in its own
/// linker namespace, so RTLD_DEFAULT lookups from inside it are not reliable.
private func loadAppScene(_ opaque: UnsafeMutableRawPointer?) -> PortScene? {
    guard let opaque else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(opaque).takeRetainedValue() as? PortScene
}

// MARK: - Runtime state

private final class AndroidRuntime {
    static let shared = AndroidRuntime()

    var runtime: OpaquePointer?
    var canvas: OpaquePointer?
    var scene: PortScene?
    var size = CGSize(width: 0, height: 0)
    var density: CGFloat = 1
    var safeArea = EdgeInsetsLike.zero
    var isDark = false
    var started = false
    var lastFrameTime: Double = 0
    var touchStart: CGPoint = .zero
    var touchConsumed = false

    func makeContext(measurer: TextMeasurer) -> SceneContext {
        SceneContext(size: size, safeArea: safeArea, isDark: isDark,
                     displayScale: density, time: ab_seconds_since_boot(),
                     measurer: measurer)
    }

    func invalidate() {
        if let runtime { ab_invalidate(runtime) }
    }
}

// MARK: - Canvas painter

/// Replays a DisplayList into the Android canvas handed over by the C bridge.
final class AndroidCanvasPainter: DisplayListPainter, TextMeasurer {
    let canvas: OpaquePointer
    let runtime: OpaquePointer?

    init(canvas: OpaquePointer, runtime: OpaquePointer?) {
        self.canvas = canvas
        self.runtime = runtime
    }

    // MARK: measurement (dp)

    func measureText(_ text: String, style: TextStyleDescriptor) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let (buffer, length) = utf8(text)
        defer { buffer.deallocate() }
        return CGFloat(ab_measure_text(canvas, buffer, length, Float(style.size),
                                       Int32(style.weight.rawValue), style.italic ? 1 : 0,
                                       Float(style.letterSpacing)))
    }

    // TextMeasurer conformance: the engine speaks `advance`/`metrics`, the painter speaks
    // `measureText`/`fontMetrics`. Same canvas calls underneath.
    func advance(_ text: String, style: TextStyleDescriptor) -> CGFloat {
        measureText(text, style: style)
    }

    func metrics(style: TextStyleDescriptor) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        fontMetrics(style: style)
    }

    func fontMetrics(style: TextStyleDescriptor) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        var ascent: Float = 0, descent: Float = 0, leading: Float = 0
        ab_font_metrics(canvas, Float(style.size), Int32(style.weight.rawValue), style.italic ? 1 : 0,
                        &ascent, &descent, &leading)
        return (CGFloat(ascent), CGFloat(descent), CGFloat(leading))
    }

    private func utf8(_ string: String) -> (UnsafeMutablePointer<CChar>, Int32) {
        let bytes = Array(string.utf8)
        let count = bytes.count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count + 1, alignment: 1)
        guard count > 0 else {
            raw.storeBytes(of: CChar(0), as: CChar.self)
            return (raw.assumingMemoryBound(to: CChar.self), 0)
        }
        bytes.withUnsafeBytes { source in
            raw.copyMemory(from: source.baseAddress!, byteCount: count)
        }
        raw.storeBytes(of: CChar(0), toByteOffset: count, as: CChar.self)
        return (raw.assumingMemoryBound(to: CChar.self), Int32(count))
    }

    // MARK: replay

    func paint(_ list: DisplayList) {
        let c = canvas
        for command in list.commands {
            switch command {
            case .save:
                ab_save(c)
            case .restore:
                ab_restore(c)
            case let .clip(rect, radius):
                if radius > 0 {
                    ab_clip_round_rect(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY), f(radius))
                } else {
                    ab_clip_rect(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY))
                }
            case let .fillRect(rect, color):
                ab_fill_rect(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY), color.argb)
            case let .fillRoundRect(rect, radius, color):
                ab_fill_round_rect(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY), f(radius), color.argb)
            case let .fillOval(rect, color):
                ab_fill_oval(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY), color.argb)
            case let .strokeRect(rect, width, color):
                ab_stroke_rect(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY), f(width), color.argb)
            case let .strokeRoundRect(rect, radius, width, color):
                ab_stroke_round_rect(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY),
                                     f(radius), f(width), color.argb)
            case let .line(from, to, width, color):
                ab_stroke_line(c, f(from.x), f(from.y), f(to.x), f(to.y), f(width), 1, color.argb)
            case let .fillPath(path, color):
                paintPath(path.encoded()) { floats, count in
                    ab_fill_path(c, floats, count, color.argb)
                }
            case let .strokePath(path, width, color):
                paintPath(path.encoded()) { floats, count in
                    ab_stroke_path(c, floats, count, f(width), 1, 1, color.argb)
                }
            case let .text(string, origin, style):
                let (buffer, length) = utf8(string)
                defer { buffer.deallocate() }
                ab_draw_text(c, buffer, length, f(origin.x), f(origin.y), f(style.size),
                             Int32(style.weight.rawValue), style.italic ? 1 : 0,
                             style.color.argb, f(style.letterSpacing))
            case let .shadowRoundRect(rect, radius, dx, dy, blur, color):
                ab_draw_shadow_round_rect(c, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY),
                                          f(radius), f(dx), f(dy), f(blur), color.argb)
            case let .linearGradient(rect, radius, start, end, stops):
                paintGradient(rect: rect, radius: radius, start: start, end: end, stops: stops)
            }
        }
    }

    private func paintPath(_ floats: [Float], _ body: (UnsafePointer<Float>, Int32) -> Void) {
        floats.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            body(base, Int32(buffer.count))
        }
    }

    private func paintGradient(rect: CGRect, radius: CGFloat, start: CGPoint, end: CGPoint, stops: [RGBAColor]) {
        guard !stops.isEmpty else { return }
        var colors = stops.map { $0.argb }
        var positions: [Float] = stops.count == 1
            ? [0]
            : (0..<stops.count).map { Float($0) / Float(stops.count - 1) }
        let count = Int32(stops.count)
        colors.withUnsafeMutableBufferPointer { colorBuffer in
            positions.withUnsafeMutableBufferPointer { positionBuffer in
                guard let colorBase = colorBuffer.baseAddress,
                      let positionBase = positionBuffer.baseAddress else { return }
                if radius > 0 {
                    ab_fill_linear_gradient_round_rect(canvas, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY),
                                                       f(radius), f(start.x), f(start.y), f(end.x), f(end.y),
                                                       colorBase, positionBase, count)
                } else {
                    ab_fill_linear_gradient_rect(canvas, f(rect.minX), f(rect.minY), f(rect.maxX), f(rect.maxY),
                                                 f(start.x), f(start.y), f(end.x), f(end.y),
                                                 colorBase, positionBase, count)
                }
            }
        }
    }

    @inline(__always) private func f(_ value: CGFloat) -> Float { Float(value) }
}

// MARK: - Text input

/// Four UTF-16 code units packed into one `jlong`: unit `i` lives in bits `16*i .. 16*i+15`, lowest
/// unit first, and a final chunk whose string does not fill it is zero-padded (the receiver trims
/// it with the length it was told). Shared by both pull protocols in this file — the initial text
/// of a text field and the URL of a link — because one bit layout means one place to get the
/// arithmetic wrong, and the View already has the matching reader.
private func packedUTF16Chunk(_ units: [UInt16], at index: Int) -> Int64 {
    var packed: UInt64 = 0
    var offset = 0
    while offset < 4, index + offset < units.count {
        packed |= UInt64(units[index + offset]) << (16 * UInt64(offset))
        offset += 1
    }
    return Int64(bitPattern: packed)
}

/// Bridges `PortTextInput` to the host View's text editor.
///
/// The direction here is the unusual one for this file: everything else runs *because* Android
/// called in through AndroidBridge.c, whereas this class is pulled from Java. The reason is that
/// a text editor cannot be expressed as drawing commands — it has to be a real `EditText` in the
/// view hierarchy, with a caret and an IME session — and this side of the process has no JNIEnv:
/// AndroidBridge.c owns every Java object by design and exposes no text-input entry point. So the
/// host View does both halves itself: it polls `nativeTextInputCommand` once per frame and after
/// every input event and pulls the pending request (slot, initial text, frame in dp) out of the
/// getters below, and it pushes the edited text back through `nativeTextChanged*`.
///
/// Text cannot cross that boundary as a jstring either, for the same reason: converting one needs
/// JNIEnv. It travels as UTF-16 code units packed four to a jlong, lowest unit first, in both
/// directions — `packedChunk(at:)` and `textChunk(_:)` are the two halves of that encoding.
private final class AndroidTextInput {
    static let shared = AndroidTextInput()

    enum Command: Int32 {
        case none = 0
        case begin = 1
        case updateFrame = 2
        case end = 3
    }

    /// The request the View is about to pull. Only one can be pending: the View drains and
    /// acknowledges it inside a single call, on the same thread.
    var command = Command.none
    var slot = 0
    var textUnits: [UInt16] = []
    var frame = CGRect.zero

    /// Snapshot being assembled from a `nativeTextChanged*` run. -1 means "no run in progress";
    /// 0 is a real length (the user deleted everything).
    private var pendingUnits: [UInt16] = []
    private var pendingLength = -1

    /// Install the host into SwiftUI. Called when the native runtime is created, i.e. before the
    /// first frame and before any control can be tapped.
    func install() {
        PortTextInput.host = PortTextInputHost(
            begin: { slot, text, frame in
                self.command = .begin
                self.slot = slot
                // Cache the UTF-16 form now: the View asks for it once per begin, but a control
                // can be re-begun while the request is still pending, and encoding then would be
                // work in the middle of a frame.
                self.textUnits = Array(text.utf16)
                self.frame = frame
            },
            updateFrame: { frame in
                self.frame = frame
                // Never downgrade a pending begin: the request the View has not seen yet then
                // carries the newest frame anyway, and turning it into "move" would leave the
                // editor closed.
                if self.command == .none {
                    self.command = .updateFrame
                }
            },
            end: {
                self.command = .end
                self.slot = 0
                self.textUnits = []
                self.frame = .zero
            })
    }

    /// Drop everything on teardown: the View and its EditText are going away with the window, so
    /// no request may survive into a later frame, and SwiftUI must not keep a session whose
    /// editor no longer exists.
    func teardown() {
        command = .none
        slot = 0
        textUnits = []
        frame = .zero
        pendingUnits = []
        pendingLength = -1
        PortTextInput.hostEnded()
    }

    /// Left/top/width/height of the pending frame in dp, as the View's four-argument getter
    /// requests it.
    func frameComponent(_ component: Int32) -> Float {
        switch component {
        case 0: return Float(frame.minX)
        case 1: return Float(frame.minY)
        case 2: return Float(frame.width)
        case 3: return Float(frame.height)
        default: return 0
        }
    }

    /// Four UTF-16 code units per jlong, lowest unit first (see `packedUTF16Chunk`).
    func packedChunk(at index: Int) -> Int64 {
        packedUTF16Chunk(textUnits, at: index)
    }

    // MARK: reverse direction (the View reports what the user typed)

    func textBegin(_ length: Int32) {
        pendingUnits.removeAll(keepingCapacity: true)
        pendingLength = max(0, Int(length))
    }

    func textChunk(_ packed: Int64) {
        guard pendingLength >= 0 else { return }
        let bits = UInt64(bitPattern: packed)
        for offset in 0..<4 {
            pendingUnits.append(UInt16(truncatingIfNeeded: bits >> (16 * UInt64(offset))))
        }
    }

    func textCommit() {
        // Typing arrives outside any draw (a Java TextWatcher callback), so nothing else would
        // schedule the frame that renders the new text: ask the platform for it here.
        defer { AndroidRuntime.shared.invalidate() }
        guard pendingLength >= 0 else { return }
        let expected = pendingLength
        let units = pendingUnits
        pendingLength = -1
        pendingUnits.removeAll(keepingCapacity: true)
        // A short run means a chunk went missing. Keep the previous text instead of delivering a
        // truncated one; every later change delivers a complete snapshot anyway.
        guard units.count >= expected else { return }
        PortTextInput.hostTextChanged(String(decoding: units[0..<expected], as: UTF16.self))
    }
}

// MARK: - Link opening

/// Bridges `PortLinkOpener` to the host View's `Intent.ACTION_VIEW`.
///
/// The direction is the same unusual one as the text editor above, and for the same reason:
/// starting an activity is a Java API, and this half of the process holds no JNIEnv — the C bridge
/// owns every Java object by design and has no "open a URL" entry point. So the host View polls
/// `nativeLinkCommand`, pulls the URL out of the getters below, acknowledges it, and only then
/// starts the Intent. Acknowledging before the launch is what makes the request single-shot: an
/// Intent that opens a chooser or pauses the activity re-enters the frame loop, and a request that
/// was still marked pending would be opened a second time by the next poll.
///
/// The URL travels as UTF-16 code units packed four to a `jlong`, the same encoding as text input
/// (`packedUTF16Chunk`). A URL is usually pure ASCII, so four characters per `jlong` is overhead;
/// it buys one transport and one reader in the View instead of a second decoder to get right.
private final class AndroidLinkOpener {
    static let shared = AndroidLinkOpener()

    enum Command: Int32 {
        case none = 0
        case open = 1
    }

    /// The request the View is about to pull. Only one can be pending: two taps before the poll
    /// leave the second URL, which is the one the user meant. The View drains and acknowledges in
    /// one call, on the same (UI) thread.
    var command = Command.none

    /// `url.absoluteString` in UTF-16 code units, cached when the request is raised so the poll
    /// does no encoding work in the middle of a frame.
    var urlUnits: [UInt16] = []

    /// Install the host when the native runtime starts, next to the text-input host: the seam
    /// belongs to the window, not to a scene, and a `Link` on the very first frame already finds
    /// it. An app that never shows a `Link` pays only a nil check per tap.
    func install() {
        PortLinkOpener.host = { url in
            self.command = .open
            self.urlUnits = Array(url.absoluteString.utf16)
            // A URL can be requested from a place that no tap invalidated (a programmatic open),
            // and the demos draw `PortLinkOpener.lastRequested` as diagnostics; ask for the frame
            // that shows it. Inside a tap this idempotently coalesces with the touch's own
            // invalidate.
            AndroidRuntime.shared.invalidate()
        }
    }

    /// Drop a pending request on teardown: the View and its window are going away, so no URL may
    /// be opened later on behalf of a dead handle.
    func teardown() {
        command = .none
        urlUnits = []
    }

    /// Four UTF-16 code units per jlong, lowest unit first (see `packedUTF16Chunk`).
    func packedChunk(at index: Int) -> Int64 {
        packedUTF16Chunk(urlUnits, at: index)
    }
}

// MARK: - C entry points

@_cdecl("swiftui_android_start")
public func swiftuiAndroidStart(_ runtime: OpaquePointer?, _ appScene: UnsafeMutableRawPointer?) {
    let state = AndroidRuntime.shared
    state.runtime = runtime
    state.scene = loadAppScene(appScene)
    state.started = true
    // The text editor belongs to the platform, not to any one scene, so it is installed here
    // rather than from the text adapter: an app that never shows a TextField pays nothing, and a
    // control that appears on the first frame already finds the host in place.
    AndroidTextInput.shared.install()
    // Same for link opening: the host View starts the ACTION_VIEW Intent, so the seam is
    // installed with the window rather than when the first Link is tapped.
    AndroidLinkOpener.shared.install()
}

@_cdecl("swiftui_android_resize")
public func swiftuiAndroidResize(_ runtime: OpaquePointer?,
                                 _ width: Float, _ height: Float, _ density: Float,
                                 _ safeTop: Float, _ safeBottom: Float,
                                 _ safeLeft: Float, _ safeRight: Float) {
    let state = AndroidRuntime.shared
    state.runtime = runtime ?? state.runtime
    state.size = CGSize(width: CGFloat(width), height: CGFloat(height))
    state.density = CGFloat(density)
    state.safeArea = EdgeInsetsLike(top: CGFloat(safeTop), bottom: CGFloat(safeBottom),
                                    leading: CGFloat(safeLeft), trailing: CGFloat(safeRight))
    state.isDark = state.runtime.map { ab_is_dark_mode($0) } ?? false
    if let canvas = state.canvas {
        let measurer = AndroidCanvasPainter(canvas: canvas, runtime: state.runtime)
        state.scene?.update(state.makeContext(measurer: measurer))
    } else {
        state.scene?.update(state.makeContext(measurer: TextMeasurement.current))
    }
    state.invalidate()
}

@_cdecl("swiftui_android_render")
public func swiftuiAndroidRender(_ runtime: OpaquePointer?,
                                 _ canvas: OpaquePointer?,
                                 _ width: Float, _ height: Float, _ density: Float) {
    guard let canvas else { return }
    let state = AndroidRuntime.shared
    state.runtime = runtime ?? state.runtime
    state.canvas = canvas
    if width > 0, height > 0 {
        state.size = CGSize(width: CGFloat(width), height: CGFloat(height))
    }
    state.density = CGFloat(density)
    state.isDark = state.runtime.map { ab_is_dark_mode($0) } ?? state.isDark

    let painter = AndroidCanvasPainter(canvas: canvas, runtime: state.runtime)
    // Text metrics come from the canvas for this frame, so layout matches rendering exactly.
    TextMeasurement.current = painter
    let context = state.makeContext(measurer: painter)
    guard let scene = state.scene else {
        var list = DisplayList()
        list.bounds = CGRect(x: 0, y: 0, width: context.size.width, height: context.size.height)
        list.append(.fillRect(list.bounds, context.isDark
            ? RGBAColor(hex: 0x101014)
            : RGBAColor(hex: 0xF7F7FA)))
        painter.paint(list)
        return
    }

    scene.update(context)
    var list = DisplayList()
    list.bounds = CGRect(origin: .zero, size: context.size)
    scene.draw(into: &list, context: context)
    painter.paint(list)
    state.lastFrameTime = context.time
    if scene.isAnimating { state.invalidate() }
}

@_cdecl("swiftui_android_touch")
public func swiftuiAndroidTouch(_ runtime: OpaquePointer?, _ phase: Int32, _ x: Float, _ y: Float, _ time: Int64) {
    let state = AndroidRuntime.shared
    state.runtime = runtime ?? state.runtime
    guard let scene = state.scene else { return }
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
    switch phase {
    case 0:   // down
        state.touchStart = point
        state.touchConsumed = false
    case 1:   // move: hand to the scene as a drag (scroll views consume it)
        let translation = hypot(point.x - state.touchStart.x, point.y - state.touchStart.y)
        if translation > 4 {
            let gesture = PortDragGesture(phase: state.touchConsumed ? .changed : .began,
                                      start: state.touchStart, location: point)
            if scene.handleDrag(gesture) {
                state.touchConsumed = true
                state.invalidate()
            }
        }
    case 2:   // up: a tap only when the pointer never really moved
        let travel = hypot(point.x - state.touchStart.x, point.y - state.touchStart.y)
        if !state.touchConsumed && travel <= 8 {
            _ = scene.handleTap(at: point)
        }
        state.invalidate()
    default:  // cancel
        state.touchConsumed = false
    }
}

@_cdecl("swiftui_android_key")
public func swiftuiAndroidKey(_ runtime: OpaquePointer?, _ action: Int32, _ keyCode: Int32) -> Bool {
    // 4 == KEYCODE_BACK; unconsumed BACK finishes the activity on the Java side.
    false
}

@_cdecl("swiftui_android_lifecycle")
public func swiftuiAndroidLifecycle(_ runtime: OpaquePointer?, _ event: Int32) {
    let state = AndroidRuntime.shared
    switch event {
    case 1:  // resume
        state.invalidate()
    case 3:  // destroy
        AndroidTextInput.shared.teardown()
        // A URL that was requested but never polled dies with the window: the View that would
        // have started the Intent is being destroyed.
        AndroidLinkOpener.shared.teardown()
        state.scene = nil
        state.canvas = nil
        state.runtime = nil
    default:
        break
    }
}

@_cdecl("swiftui_android_low_memory")
public func swiftuiAndroidLowMemory(_ runtime: OpaquePointer?) {
    // Nothing cached yet beyond the per-frame painters; reserved for image caches.
}

// MARK: - Text input JNI
//
// These run in the opposite direction to the entry points above: the host View calls them, so
// they are declared in SwiftUIHostView.java as `native`. ART resolves an unregistered native
// method by looking for `Java_<mangled class>_<mangled method>` in the loaded libraries, so a
// @_cdecl carrying the mangled name *is* the JNI implementation. That keeps text input out of
// AndroidBridge.c, which owns every JNI object and deliberately exposes no text-input seam.
// The first two parameters are the JNIEnv and jclass every JNI function receives; they are
// unused on purpose — this layer never touches a JNI object (see AndroidTextInput for the packed
// UTF-16 transport). The trailing `handle` is the ABRuntime the View was created with; the
// bridge is a per-process singleton because there is exactly one host View, and the View already
// refuses to call in with a dead handle.
//
// The Java declarations, in this order (app/src/dev/swiftui/android/SwiftUIHostView.java):
//
//   nativeTextInputCommand(long) -> int         0 none, 1 begin, 2 update frame, 3 end
//   nativeTextInputSlot(long) -> int            the control that owns the editor
//   nativeTextInputFrame(long, int) -> float    0 left, 1 top, 2 width, 3 height (dp)
//   nativeTextInputTextLength(long) -> int      UTF-16 code units of the initial text
//   nativeTextInputTextChunk(long, int) -> long 4 code units starting at that unit offset
//   nativeTextInputAck(long) -> void            the pending request has been consumed
//   nativeTextChangedBegin(long, int) -> void   start of a whole-text snapshot (its length)
//   nativeTextChangedChunk(long, long) -> void  one 4-unit chunk of that snapshot
//   nativeTextChangedCommit(long) -> void       the snapshot is complete
//   nativeTextEnded(long, int) -> void          the editor closed by itself

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextInputCommand")
public func jniTextInputCommand(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                                _ handle: Int64) -> Int32 {
    AndroidTextInput.shared.command.rawValue
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextInputSlot")
public func jniTextInputSlot(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                             _ handle: Int64) -> Int32 {
    Int32(AndroidTextInput.shared.slot)
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextInputFrame")
public func jniTextInputFrame(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                              _ handle: Int64, _ component: Int32) -> Float {
    AndroidTextInput.shared.frameComponent(component)
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextInputTextLength")
public func jniTextInputTextLength(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                                   _ handle: Int64) -> Int32 {
    Int32(AndroidTextInput.shared.textUnits.count)
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextInputTextChunk")
public func jniTextInputTextChunk(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                                  _ handle: Int64, _ index: Int32) -> Int64 {
    AndroidTextInput.shared.packedChunk(at: max(0, Int(index)))
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextInputAck")
public func jniTextInputAck(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                            _ handle: Int64) {
    AndroidTextInput.shared.command = .none
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextChangedBegin")
public func jniTextChangedBegin(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                                _ handle: Int64, _ length: Int32) {
    AndroidTextInput.shared.textBegin(length)
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextChangedChunk")
public func jniTextChangedChunk(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                                _ handle: Int64, _ packed: Int64) {
    AndroidTextInput.shared.textChunk(packed)
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextChangedCommit")
public func jniTextChangedCommit(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                                 _ handle: Int64) {
    AndroidTextInput.shared.textCommit()
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeTextEnded")
public func jniTextEnded(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                         _ handle: Int64, _ reason: Int32) {
    // The reason (0 IME action, 1 cancelled, 2 focus lost, 3 host destroyed) is already in
    // logcat on the Java side; SwiftUI only needs to know that the session is over.
    _ = reason
    PortTextInput.hostEnded()
    // The caret and the focus ring are drawn by SwiftUI, so the end of a platform-initiated
    // session needs a frame of its own.
    AndroidRuntime.shared.invalidate()
}

// MARK: - Link opening JNI
//
// The same unregistered-native trick as the text-input functions above: the host View declares
// these as `native`, ART resolves each to its mangled `@_cdecl` name, and no JNI object is ever
// touched here. The host View polls, reads and acknowledges; see `AndroidLinkOpener`.
//
// The Java declarations, in this order (app/src/dev/swiftui/android/SwiftUIHostView.java):
//
//   nativeLinkCommand(long) -> int            0 none, 1 open a URL
//   nativeLinkUrlLength(long) -> int          UTF-16 code units of the pending URL
//   nativeLinkUrlChunk(long, int) -> long     4 code units starting at that unit offset
//   nativeLinkAck(long) -> void               the pending request has been consumed

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeLinkCommand")
public func jniLinkCommand(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                           _ handle: Int64) -> Int32 {
    AndroidLinkOpener.shared.command.rawValue
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeLinkUrlLength")
public func jniLinkUrlLength(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                             _ handle: Int64) -> Int32 {
    Int32(AndroidLinkOpener.shared.urlUnits.count)
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeLinkUrlChunk")
public func jniLinkUrlChunk(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                            _ handle: Int64, _ index: Int32) -> Int64 {
    AndroidLinkOpener.shared.packedChunk(at: max(0, Int(index)))
}

@_cdecl("Java_dev_swiftui_android_SwiftUIHostView_nativeLinkAck")
public func jniLinkAck(_ env: UnsafeMutableRawPointer?, _ clazz: UnsafeRawPointer?,
                       _ handle: Int64) {
    // The URL is dropped together with the flag, so a second acknowledgment (or a later poll that
    // somehow still saw `open`) has nothing left to read: a consumed request can never be
    // replayed into a second Intent.
    AndroidLinkOpener.shared.teardown()
}

#endif  // os(Android)
