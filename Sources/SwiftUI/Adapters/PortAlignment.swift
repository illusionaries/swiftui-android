// PortAlignment.swift — alignment identities and their geometric meaning.
//
// Apple's `HorizontalAlignment`/`VerticalAlignment` wrap an opaque `AlignmentKey` (a single `UInt`
// that indexes a table of alignment types). The values behind the public statics live in Apple's
// binary, so recompiled from text `.center` traps. The port keeps the same representation — a
// tag — and registers each alignment's multiplier so layout can ask "where does this guide sit?".
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#else
import Foundation
#endif

enum PortAlignmentRegistry {
    /// tag → position along the axis (0 = leading/top, 0.5 = center, 1 = trailing/bottom)
    nonisolated(unsafe) private static var positions: [UInt: CGFloat] = [:]

    static func tag(for id: Any.Type) -> UInt {
        unsafeBitCast(ObjectIdentifier(id), to: UInt.self)
    }

    @discardableResult
    static func register(_ id: Any.Type, position: CGFloat) -> UInt {
        let tag = tag(for: id)
        positions[tag] = position
        return tag
    }

    static func position(for tag: UInt) -> CGFloat? { positions[tag] }

    static func position(of alignment: HorizontalAlignment) -> CGFloat {
        position(for: unsafeBitCast(alignment, to: UInt.self)) ?? 0.5
    }

    static func position(of alignment: VerticalAlignment) -> CGFloat {
        position(for: unsafeBitCast(alignment, to: UInt.self)) ?? 0.5
    }
}

// MARK: - Alignment identifiers (Apple's `AlignmentID` conformances)

struct PortLeadingAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { 0 }
}

struct PortCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.width / 2 }
}

struct PortTrailingAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.width }
}

struct PortTopAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { 0 }
}

struct PortBottomAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.height }
}

// MARK: - HorizontalAlignment

extension HorizontalAlignment {
    public init(_ id: any AlignmentID.Type) {
        let position: CGFloat
        switch ObjectIdentifier(id) {
        case ObjectIdentifier(PortLeadingAlignment.self): position = 0
        case ObjectIdentifier(PortTrailingAlignment.self): position = 1
        default: position = 0.5
        }
        let tag = PortAlignmentRegistry.register(id, position: position)
        self = unsafeBitCast(tag, to: HorizontalAlignment.self)
    }

    public static var leading: HorizontalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortLeadingAlignment.self, position: 0),
                      to: HorizontalAlignment.self)
    }

    public static var center: HorizontalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortCenterAlignment.self, position: 0.5),
                      to: HorizontalAlignment.self)
    }

    public static var trailing: HorizontalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortTrailingAlignment.self, position: 1),
                      to: HorizontalAlignment.self)
    }

    public static func == (a: HorizontalAlignment, b: HorizontalAlignment) -> Bool {
        unsafeBitCast(a, to: UInt.self) == unsafeBitCast(b, to: UInt.self)
    }
}

// MARK: - VerticalAlignment

extension VerticalAlignment {
    public init(_ id: any AlignmentID.Type) {
        let position: CGFloat
        switch ObjectIdentifier(id) {
        case ObjectIdentifier(PortTopAlignment.self): position = 0
        case ObjectIdentifier(PortBottomAlignment.self): position = 1
        default: position = 0.5
        }
        let tag = PortAlignmentRegistry.register(id, position: position)
        self = unsafeBitCast(tag, to: VerticalAlignment.self)
    }

    public static var top: VerticalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortTopAlignment.self, position: 0),
                      to: VerticalAlignment.self)
    }

    public static var center: VerticalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortCenterAlignment.self, position: 0.5),
                      to: VerticalAlignment.self)
    }

    public static var bottom: VerticalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortBottomAlignment.self, position: 1),
                      to: VerticalAlignment.self)
    }

    public static var firstTextBaseline: VerticalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortTopAlignment.self, position: 0.8),
                      to: VerticalAlignment.self)
    }

    public static var lastTextBaseline: VerticalAlignment {
        unsafeBitCast(PortAlignmentRegistry.register(PortBottomAlignment.self, position: 0.8),
                      to: VerticalAlignment.self)
    }

    public static func == (a: VerticalAlignment, b: VerticalAlignment) -> Bool {
        unsafeBitCast(a, to: UInt.self) == unsafeBitCast(b, to: UInt.self)
    }
}

// MARK: - Alignment

extension Alignment {
    public static var center: Alignment {
        Alignment(horizontal: .center, vertical: .center)
    }

    public static var leading: Alignment {
        Alignment(horizontal: .leading, vertical: .center)
    }

    public static var trailing: Alignment {
        Alignment(horizontal: .trailing, vertical: .center)
    }

    public static var top: Alignment {
        Alignment(horizontal: .center, vertical: .top)
    }

    public static var bottom: Alignment {
        Alignment(horizontal: .center, vertical: .bottom)
    }

    public static var topLeading: Alignment {
        Alignment(horizontal: .leading, vertical: .top)
    }

    public static var topTrailing: Alignment {
        Alignment(horizontal: .trailing, vertical: .top)
    }

    public static var bottomLeading: Alignment {
        Alignment(horizontal: .leading, vertical: .bottom)
    }

    public static var bottomTrailing: Alignment {
        Alignment(horizontal: .trailing, vertical: .bottom)
    }

    public static func == (a: Alignment, b: Alignment) -> Bool {
        a.horizontal == b.horizontal && a.vertical == b.vertical
    }
}
