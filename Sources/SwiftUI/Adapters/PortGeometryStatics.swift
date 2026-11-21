// PortGeometryStatics.swift — the storage-backed geometry constants Apple's binary provides.
//
// Apple's interface declares these as static storage (no initializer), so recompiled from text
// they become computed properties that trap. Each one is an OptionSet bit or a trivial value, so
// the port defines them directly; the declarations stay Apple's, only the values are supplied.
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#else
import Foundation
#endif

// MARK: - Edge.Set
// `Edge` has raw values in declaration order (top 0, leading 1, bottom 2, trailing 3); the bit
// positions below follow that order. (`Edge.rawValue` itself is one of Apple's stored statics, so
// the constants are spelled out rather than computed through it.)

extension Edge.Set {
    public static var top: Edge.Set { _optionSet(1 << 0, as: Edge.Set.self) }
    public static var leading: Edge.Set { _optionSet(1 << 1, as: Edge.Set.self) }
    public static var bottom: Edge.Set { _optionSet(1 << 2, as: Edge.Set.self) }
    public static var trailing: Edge.Set { _optionSet(1 << 3, as: Edge.Set.self) }
    public static var horizontal: Edge.Set { _optionSet((1 << 1) | (1 << 3), as: Edge.Set.self) }
    public static var vertical: Edge.Set { _optionSet((1 << 0) | (1 << 2), as: Edge.Set.self) }
    public static var all: Edge.Set { _optionSet((1 << 0) | (1 << 1) | (1 << 2) | (1 << 3), as: Edge.Set.self) }
}

// MARK: - HorizontalDirection.Set / VerticalDirection.Set

/// OptionSet values are a single raw value; constructing them by bit pattern avoids the
/// ambiguity between the port's public `init(rawValue:)` witness and the compiler's implicit
/// internal memberwise initializer.
@inline(__always)
func _optionSet<S>(_ bits: Int8, as: S.Type) -> S {
    unsafeBitCast(bits, to: S.self)
}

extension HorizontalDirection.Set {
    public init(_ direction: HorizontalDirection) {
        switch direction {
        case .leading: self = .leading
        case .trailing: self = .trailing
        }
    }

    public static var leading: HorizontalDirection.Set { _optionSet(1 << 0, as: HorizontalDirection.Set.self) }
    public static var trailing: HorizontalDirection.Set { _optionSet(1 << 1, as: HorizontalDirection.Set.self) }
    public static var all: HorizontalDirection.Set { _optionSet((1 << 0) | (1 << 1), as: HorizontalDirection.Set.self) }
}

extension VerticalDirection.Set {
    public init(_ direction: VerticalDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        }
    }

    public static var up: VerticalDirection.Set { _optionSet(1 << 0, as: VerticalDirection.Set.self) }
    public static var down: VerticalDirection.Set { _optionSet(1 << 1, as: VerticalDirection.Set.self) }
    public static var all: VerticalDirection.Set { _optionSet((1 << 0) | (1 << 1), as: VerticalDirection.Set.self) }
}

// MARK: - EdgeInsets

extension EdgeInsets {
    public init(_all value: CGFloat) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }

    /// `EdgeInsets.inset(by:edges:)` — Apple applies an `EdgeInsets` only on the given edges.
    public func inset(by amount: EdgeInsets, edges: Edge.Set) -> EdgeInsets {
        var result = self
        if edges.contains(.top) { result.top += amount.top }
        if edges.contains(.leading) { result.leading += amount.leading }
        if edges.contains(.bottom) { result.bottom += amount.bottom }
        if edges.contains(.trailing) { result.trailing += amount.trailing }
        return result
    }
}
