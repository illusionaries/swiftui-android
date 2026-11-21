// Geometry primitives.
//
// On Darwin, CoreGraphics supplies CGFloat/CGPoint/CGSize/CGRect; on Android and other
// non-Darwin platforms, Foundation's swift-corelibs implementation supplies the same types.
// We never redeclare them — we only add helpers with names that cannot collide.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

public typealias CGFloat = Double

// MARK: - Proposed size

/// The size a parent offers to a child during layout. `nil` means "your natural size".
public struct ProposedViewSize: Equatable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?

    public init(width: CGFloat?, height: CGFloat?) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.width = size.width
        self.height = size.height
    }

    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)

    /// Replaces nil dimensions with the given values.
    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize {
        CGSize(width: width ?? size.width, height: height ?? size.height)
    }

    public func replacingUnspecifiedDimensions(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: self.width ?? width, height: self.height ?? height)
    }
}

// MARK: - Axis

public enum Axis: Sendable {
    case horizontal
    case vertical

    public var perpendicular: Axis {
        self == .horizontal ? .vertical : .horizontal
    }
}

// MARK: - Edge

public enum Edge: Hashable, Sendable {
    case top, leading, bottom, trailing

    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1 << 0)
        public static let leading = Set(rawValue: 1 << 1)
        public static let bottom = Set(rawValue: 1 << 2)
        public static let trailing = Set(rawValue: 1 << 3)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

// MARK: - EdgeInsets

public struct EdgeInsets: Equatable, Hashable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(_ value: CGFloat) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }

    public init(horizontal: CGFloat = 0, vertical: CGFloat = 0) {
        self.init(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    public static let zero = EdgeInsets(0)

    public var horizontal: CGFloat { leading + trailing }
    public var vertical: CGFloat { top + bottom }
}

// MARK: - Alignment

public struct HorizontalAlignment: Hashable, Sendable {
    public let id: Int
    public let multiplier: CGFloat     // 0 = leading, 0.5 = center, 1 = trailing
    public init(id: Int, multiplier: CGFloat) {
        self.id = id
        self.multiplier = multiplier
    }

    public static let leading = HorizontalAlignment(id: 0, multiplier: 0)
    public static let center = HorizontalAlignment(id: 1, multiplier: 0.5)
    public static let trailing = HorizontalAlignment(id: 2, multiplier: 1)
}

public struct VerticalAlignment: Hashable, Sendable {
    public let id: Int
    public let multiplier: CGFloat
    public init(id: Int, multiplier: CGFloat) {
        self.id = id
        self.multiplier = multiplier
    }

    public static let top = VerticalAlignment(id: 0, multiplier: 0)
    public static let center = VerticalAlignment(id: 1, multiplier: 0.5)
    public static let bottom = VerticalAlignment(id: 2, multiplier: 1)
    public static let firstTextBaseline = VerticalAlignment(id: 3, multiplier: 0.8)
    public static let lastTextBaseline = VerticalAlignment(id: 4, multiplier: 0.8)
}

public struct Alignment: Hashable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
}

// MARK: - UnitPoint

public struct UnitPoint: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let zero = UnitPoint(x: 0, y: 0)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

// MARK: - Angle

public struct Angle: Hashable, Sendable {
    public var degrees: CGFloat
    public init(degrees: CGFloat) {
        self.degrees = degrees
    }

    public static func radians(_ radians: CGFloat) -> Angle {
        Angle(degrees: radians * 180 / .pi)
    }

    public var radians: CGFloat { degrees * .pi / 180 }

    public static let zero = Angle(degrees: 0)
    public static func degrees(_ value: CGFloat) -> Angle { Angle(degrees: value) }
}

// MARK: - Geometry helpers used across the engine

@inline(__always)
func sMin(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a < b ? a : b }

@inline(__always)
func sMax(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a > b ? a : b }

@inline(__always)
func sClamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    sMin(sMax(value, lower), upper)
}

extension CGRect {
    /// Insets this rect by an EdgeInsets (leading/trailing map to x, top/bottom to y).
    func applying(_ insets: EdgeInsets) -> CGRect {
        CGRect(
            x: origin.x + insets.leading,
            y: origin.y + insets.top,
            width: sMax(0, size.width - insets.horizontal),
            height: sMax(0, size.height - insets.vertical)
        )
    }

    func translated(byX dx: CGFloat, y dy: CGFloat) -> CGRect {
        CGRect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
    }

    var sCenter: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func sContains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func sUnion(_ other: CGRect) -> CGRect {
        if other.isEmpty { return self }
        if isEmpty { return other }
        let minX = Swift.min(self.minX, other.minX)
        let minY = Swift.min(self.minY, other.minY)
        let maxX = Swift.max(self.maxX, other.maxX)
        let maxY = Swift.max(self.maxY, other.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Frame of `size` placed inside this rect according to `alignment`.
    func aligning(_ size: CGSize, in rect: CGRect, alignment: Alignment) -> CGRect {
        CGRect(
            x: rect.minX + (rect.width - size.width) * alignment.horizontal.multiplier,
            y: rect.minY + (rect.height - size.height) * alignment.vertical.multiplier,
            width: size.width,
            height: size.height
        )
    }

    /// The largest centered rect with the given aspect ratio.
    func aspectFit(_ aspect: CGFloat) -> CGRect {
        guard aspect > 0, width > 0, height > 0 else { return self }
        let containerAspect = width / height
        if containerAspect > aspect {
            let w = height * aspect
            return CGRect(x: minX + (width - w) / 2, y: minY, width: w, height: height)
        } else {
            let h = width / aspect
            return CGRect(x: minX, y: minY + (height - h) / 2, width: width, height: h)
        }
    }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    static func - (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
    }

    var sMaxDimension: CGFloat { Swift.max(width, height) }
}
