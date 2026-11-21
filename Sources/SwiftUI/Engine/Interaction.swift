// Interaction.swift — pointer input shared by every backend.
//
// A scene receives a small, platform-free vocabulary: taps, drags (for scrolling), and
// long-press-free simplicity. The Android runtime translates MotionEvent into these.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

public enum DragPhase: Equatable {
    case began
    case changed
    case ended
    case cancelled
}

public struct PortDragGesture: Equatable {
    public var phase: DragPhase
    public var start: CGPoint
    public var location: CGPoint

    public init(phase: DragPhase, start: CGPoint, location: CGPoint) {
        self.phase = phase
        self.start = start
        self.location = location
    }

    public var translation: CGPoint {
        CGPoint(x: location.x - start.x, y: location.y - start.y)
    }
}

public extension PortScene {
    /// Default: the scene does not scroll.
    func handleDrag(_ gesture: PortDragGesture) -> Bool { false }
}

/// Simple scroll model: content height vs. viewport, with fling-free clamping.
/// Kept deliberately small; the SwiftUI `ScrollView` adapter will drive the same model.
public struct ScrollModel: Equatable {
    public var offset: CGFloat = 0
    public var contentHeight: CGFloat = 0
    public var viewportHeight: CGFloat = 0

    public init() {}

    public var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }

    public mutating func clamp() {
        offset = min(max(0, offset), maxOffset)
    }

    public mutating func scroll(by delta: CGFloat) {
        offset += delta
        clamp()
    }

    public var canScroll: Bool { maxOffset > 0.5 }
}
