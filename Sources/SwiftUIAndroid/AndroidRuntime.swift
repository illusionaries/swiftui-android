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

// MARK: - Scene resolution

private typealias SceneEntryPoint = @convention(c) () -> UnsafeMutableRawPointer?

@_silgen_name("dlsym")
private func c_dlsym(_ handle: UnsafeMutableRawPointer?, _ symbol: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?

private func loadAppScene() -> PortScene? {
    // The demo app (or any app) exports a single C symbol returning a retained PortScene.
    // RTLD_DEFAULT: symbols of this process image (both targets live in the same .so).
    guard let symbol = c_dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swiftui_app_entry") else {
        return nil
    }
    let entry = unsafeBitCast(symbol, to: SceneEntryPoint.self)
    guard let opaque = entry() else { return nil }
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

    func makeContext() -> SceneContext {
        SceneContext(size: size, safeArea: safeArea, isDark: isDark,
                     displayScale: density, time: ab_seconds_since_boot())
    }

    func invalidate() {
        if let runtime { ab_invalidate(runtime) }
    }
}

// MARK: - Canvas painter

/// Replays a DisplayList into the Android canvas handed over by the C bridge.
final class AndroidCanvasPainter: DisplayListPainter {
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

// MARK: - C entry points

@_cdecl("swiftui_android_start")
public func swiftuiAndroidStart(_ runtime: OpaquePointer?) {
    let state = AndroidRuntime.shared
    state.runtime = runtime
    state.scene = loadAppScene()
    state.started = true
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
    state.scene?.update(state.makeContext())
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

    let context = state.makeContext()
    guard let scene = state.scene else {
        let painter = AndroidCanvasPainter(canvas: canvas, runtime: state.runtime)
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
    AndroidCanvasPainter(canvas: canvas, runtime: state.runtime).paint(list)
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
        _ = scene.handleTap(at: point)
        state.invalidate()
    case 1:   // move
        break
    case 2:   // up
        state.invalidate()
    default:  // cancel
        break
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
