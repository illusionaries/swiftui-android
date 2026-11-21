// PortStyle.swift — colours, fonts and shape styles on the ported path.
//
// Apple stores all three behind opaque box classes (`AnyColorBox`, `AnyFontBox`, …) whose real
// payload lives in its binary. Each of these types is a `@frozen` struct wrapping exactly one
// class reference, so the port carries its own boxes:
//
//   • the platform values the app creates (`Color.red`, `Font.title`, `.system(size:)`) are built
//     here and registered in a side table keyed by the box pointer;
//   • reading a value back is a pointer lookup, never a dereference, so a value that did not come
//     from this file degrades to the environment default instead of crashing.
//
// That keeps Apple's declarations untouched while giving the engine real colours and type metrics.
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#else
import Foundation
#endif

// MARK: - Colours

/// One box per port-created `Color`, carrying its sRGB value.
final class PortColorBox: AnyColorBox {
    let rgba: RGBAColor

    init(_ rgba: RGBAColor) {
        self.rgba = rgba
        super.init()
    }
}

/// Type metrics for a port-created `Font`.
public struct PortFontSpec: Equatable {
    public var size: CGFloat
    public var weight: Font.Weight

    public init(size: CGFloat, weight: Font.Weight = .regular) {
        self.size = size
        self.weight = weight
    }
}

final class PortFontBox: AnyFontBox {
    let spec: PortFontSpec

    init(_ spec: PortFontSpec) {
        self.spec = spec
        super.init()
    }
}

public enum PortStyleRegistry {
    nonisolated(unsafe) private static var colors: [UInt: RGBAColor] = [:]
    nonisolated(unsafe) private static var fonts: [UInt: PortFontSpec] = [:]

    /// Bit pattern of the single class reference a `Color`/`Font` stores.
    static func pointer<V>(of value: V) -> UInt {
        unsafeBitCast(value, to: UInt.self)
    }

    static func color(_ rgba: RGBAColor) -> Color {
        let pointer = UnsafeMutableRawPointer(Unmanaged.passRetained(PortColorBox(rgba)).toOpaque())
        colors[UInt(bitPattern: pointer)] = rgba
        return unsafeBitCast(pointer, to: Color.self)
    }

    static func rgba(of color: Color) -> RGBAColor? {
        colors[pointer(of: color)]
    }

    static func font(_ spec: PortFontSpec) -> Font {
        let pointer = UnsafeMutableRawPointer(Unmanaged.passRetained(PortFontBox(spec)).toOpaque())
        fonts[UInt(bitPattern: pointer)] = spec
        return unsafeBitCast(pointer, to: Font.self)
    }

    static func spec(of font: Font) -> PortFontSpec? {
        fonts[pointer(of: font)]
    }
}

// MARK: - Color values

extension Color {
    static func _port(_ rgba: RGBAColor) -> Color {
        PortStyleRegistry.color(rgba)
    }

    /// Directional colour pairs collapse to their light variant; the engine has one appearance per
    /// frame and the adapters already know whether it is dark.
    static func _port(light: RGBAColor, dark: RGBAColor) -> Color {
        PortStyleRegistry.color(light)
    }

    public static var red: Color { ._port(RGBAColor(hex: 0xFF3B30)) }
    public static var orange: Color { ._port(RGBAColor(hex: 0xFF9500)) }
    public static var yellow: Color { ._port(RGBAColor(hex: 0xFFCC00)) }
    public static var green: Color { ._port(RGBAColor(hex: 0x34C759)) }
    public static var mint: Color { ._port(RGBAColor(hex: 0x00C7BE)) }
    public static var teal: Color { ._port(RGBAColor(hex: 0x30B0C7)) }
    public static var cyan: Color { ._port(RGBAColor(hex: 0x32ADE6)) }
    public static var blue: Color { ._port(RGBAColor(hex: 0x007AFF)) }
    public static var indigo: Color { ._port(RGBAColor(hex: 0x5856D6)) }
    public static var purple: Color { ._port(RGBAColor(hex: 0xAF52DE)) }
    public static var pink: Color { ._port(RGBAColor(hex: 0xFF2D55)) }
    public static var brown: Color { ._port(RGBAColor(hex: 0xA2845E)) }
    public static var white: Color { ._port(RGBAColor(hex: 0xFFFFFF)) }
    public static var gray: Color { ._port(RGBAColor(hex: 0x8E8E93)) }
    public static var black: Color { ._port(RGBAColor(hex: 0x000000)) }
    public static var clear: Color { ._port(RGBAColor(hex: 0x000000, alpha: 0)) }
    public static var primary: Color { ._port(RGBAColor(hex: 0x111114)) }
    public static var secondary: Color { ._port(RGBAColor(hex: 0x6E6E73)) }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self = ._port(RGBAColor(red: red, green: green, blue: blue, alpha: opacity))
    }

    public init(white: Double, opacity: Double = 1) {
        self = ._port(RGBAColor(red: white, green: white, blue: white, alpha: opacity))
    }

    public init(hue: Double, saturation: Double, brightness: Double, opacity: Double = 1) {
        let (r, g, b) = PortStyleRegistry.hsb(hue: hue, saturation: saturation, brightness: brightness)
        self = ._port(RGBAColor(red: r, green: g, blue: b, alpha: opacity))
    }

    public func opacity(_ opacity: Double) -> Color {
        guard let base = PortStyleRegistry.rgba(of: self) else { return self }
        return ._port(RGBAColor(red: base.red, green: base.green, blue: base.blue,
                                alpha: base.alpha * opacity))
    }

    public static func == (lhs: Color, rhs: Color) -> Bool {
        PortStyleRegistry.pointer(of: lhs) == PortStyleRegistry.pointer(of: rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(PortStyleRegistry.pointer(of: self))
    }
}

extension PortStyleRegistry {
    /// HSB → RGB, the one bit of colour maths `Color(hue:…)` needs.
    static func hsb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let sector = Int(h)
        let fraction = h - Double(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch sector % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}

// MARK: - Fonts

extension Font {
    static func _port(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        PortStyleRegistry.font(PortFontSpec(size: size, weight: weight))
    }

    public static var largeTitle: Font { ._port(size: 34, weight: .bold) }
    public static var title: Font { ._port(size: 28) }
    public static var title2: Font { ._port(size: 22) }
    public static var title3: Font { ._port(size: 20) }
    public static var headline: Font { ._port(size: 17, weight: .semibold) }
    public static var body: Font { ._port(size: 17) }
    public static var callout: Font { ._port(size: 16) }
    public static var subheadline: Font { ._port(size: 15) }
    public static var footnote: Font { ._port(size: 13) }
    public static var caption: Font { ._port(size: 12) }
    public static var caption2: Font { ._port(size: 11) }

    public static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        ._port(size: size, weight: weight)
    }

    public static func system(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
        ._port(size: 17)
    }

    public func weight(_ weight: Font.Weight) -> Font {
        var spec = PortStyleRegistry.spec(of: self) ?? PortFontSpec(size: 17, weight: .regular)
        spec.weight = weight
        return ._port(size: spec.size, weight: spec.weight)
    }

    public func bold() -> Font { weight(.bold) }

    public func italic() -> Font { self }

    public func monospaced() -> Font { self }

    public static func == (lhs: Font, rhs: Font) -> Bool {
        PortStyleRegistry.pointer(of: lhs) == PortStyleRegistry.pointer(of: rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(PortStyleRegistry.pointer(of: self))
    }
}

// MARK: - Shape styles

extension ShapeKind {
    /// Maps Apple's shape types onto the engine's primitives.
    static func kind<Content: Shape>(for shape: Content) -> ShapeKind {
        if shape is Rectangle { return .rectangle }
        if let rounded = shape as? RoundedRectangle { return .roundedRectangle(cornerRadius: rounded.cornerSize.width) }
        if shape is Circle { return .circle }
        if shape is Capsule { return .capsule }
        return .rectangle
    }
}

// MARK: - Font.Weight
//
// `Font.Weight` wraps a numeric weight (`package var value`), which is real storage in the
// interface, so the standard weights are simply their CSS-style numbers.

extension Font.Weight {
    public static var ultraLight: Font.Weight { Font.Weight(value: 100) }
    public static var thin: Font.Weight { Font.Weight(value: 200) }
    public static var light: Font.Weight { Font.Weight(value: 300) }
    public static var regular: Font.Weight { Font.Weight(value: 400) }
    public static var medium: Font.Weight { Font.Weight(value: 500) }
    public static var semibold: Font.Weight { Font.Weight(value: 600) }
    public static var bold: Font.Weight { Font.Weight(value: 700) }
    public static var heavy: Font.Weight { Font.Weight(value: 800) }
    public static var black: Font.Weight { Font.Weight(value: 900) }

    public static func == (a: Font.Weight, b: Font.Weight) -> Bool { a.value == b.value }

    public func hash(into hasher: inout Hasher) { hasher.combine(value) }

    public var hashValue: Int { Int(value) }
}
