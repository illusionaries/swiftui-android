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
    /// Offset when the current drag started. `PortDragGesture.translation` is measured from the
    /// touch-down point and therefore grows on every move event; adding it to the *current* offset
    /// re-applied the whole travel each time and the content ran away from the finger. A drag is
    /// `base + translation`, not `offset + translation`.
    public var dragBaseOffset: CGFloat?

    public init() {}

    public var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }

    public mutating func clamp() {
        offset = min(max(0, offset), maxOffset)
    }

    /// Move the content with a gesture: the first event of a drag fixes the base, later ones
    /// re-derive the offset from it.
    public mutating func track(_ gesture: PortDragGesture) {
        if dragBaseOffset == nil || gesture.phase == .began {
            dragBaseOffset = offset
        }
        offset = (dragBaseOffset ?? offset) - gesture.translation.y
        clamp()
    }

    public mutating func scroll(by delta: CGFloat) {
        offset += delta
        clamp()
    }

    public var canScroll: Bool { maxOffset > 0.5 }
}
