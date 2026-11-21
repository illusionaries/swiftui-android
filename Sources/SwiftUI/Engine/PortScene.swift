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

    public init(size: CGSize, safeArea: EdgeInsetsLike, isDark: Bool, displayScale: CGFloat, time: Double) {
        self.size = size
        self.safeArea = safeArea
        self.isDark = isDark
        self.displayScale = displayScale
        self.time = time
    }
}

/// Platform-agnostic inset set (Android insets arrive through the bridge).
public struct EdgeInsetsLike: Equatable {
    public var top: CGFloat
    public var bottom: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, bottom: CGFloat = 0, leading: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }

    public static let zero = EdgeInsetsLike()
}

public protocol PortScene: AnyObject {
    func update(_ context: SceneContext)
    func draw(into displayList: inout DisplayList, context: SceneContext)
    /// Returns true when the scene consumed the tap.
    func handleTap(at point: CGPoint) -> Bool
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
