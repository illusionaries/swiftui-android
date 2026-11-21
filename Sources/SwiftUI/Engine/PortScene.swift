// PortScene.swift — the port's scene abstraction.
//
// Apple's own `App`/`Scene`/`ViewGraph` machinery is internal to the closed-source binary,
// so the port defines the minimal seam it needs: a scene that lays out and draws itself into
// a DisplayList. SwiftUI `View` values adapt to it in Engine/ViewAdapter.swift; until that
// adapter lands, scene implementations may draw directly.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

public struct SceneContext {
    public var size: CGSize
    public var safeArea: EdgeInsetsLike
    /// True when the platform is in dark mode.
    public var isDark: Bool
    /// Points per pixel (Android density), for hairline widths.
    public var displayScale: CGFloat
    public var time: Double
    /// Text metrics for this frame. The platform backend supplies a canvas-backed measurer;
    /// the scene installs it before laying out.
    public var measurer: TextMeasurer

    public init(size: CGSize, safeArea: EdgeInsetsLike, isDark: Bool, displayScale: CGFloat,
                time: Double, measurer: TextMeasurer = TextMeasurement.current) {
        self.measurer = measurer
        self.size = size
        self.safeArea = safeArea
        self.isDark = isDark
        self.displayScale = displayScale
        self.time = time
    }
}

public protocol PortScene: AnyObject {
    func update(_ context: SceneContext)
    func draw(into displayList: inout DisplayList, context: SceneContext)
    /// Returns true when the scene consumed the tap.
    func handleTap(at point: CGPoint) -> Bool
    /// Returns true when the scene consumed the drag (e.g. it scrolled). Declared as a
    /// requirement so scenes that implement it are dispatched dynamically — an extension-only
    /// method would be statically dispatched and never reach the scene.
    func handleDrag(_ gesture: DragGesture) -> Bool
    /// True while the scene wants continuous frames (animations).
    var isAnimating: Bool { get }
}

public extension PortScene {
    func handleTap(at point: CGPoint) -> Bool { false }
    var isAnimating: Bool { false }
}

/// Scenes are identified by name so the demo can be swapped without touching the runtime.
public enum PortSceneRegistry {
    nonisolated(unsafe) public static var makeScene: (() -> PortScene)?
}
