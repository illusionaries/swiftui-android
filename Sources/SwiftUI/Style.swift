// Color, gradients and fonts — the style primitives the display list carries.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

// MARK: - Color

/// A resolved sRGB color. `Color` in SwiftUI is a *style* that resolves against the
/// environment; we keep the light/dark pair so the engine can resolve lazily.
public struct Color: Hashable, Sendable {
    public struct RGBA: Hashable, Sendable {
        public var red: CGFloat
        public var green: CGFloat
        public var blue: CGFloat
        public var alpha: CGFloat

        public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        public init(white: CGFloat, alpha: CGFloat = 1) {
            self.init(red: white, green: white, blue: white, alpha: alpha)
        }

        /// 0xRRGGBB / 0xRRGGBBAA style literal.
        public init(hex: UInt32, alpha: CGFloat = 1) {
            self.init(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        }

        public var argb: UInt32 {
            let a = UInt32((alpha.clamped01) * 255 + 0.5)
            let r = UInt32((red.clamped01) * 255 + 0.5)
            let g = UInt32((green.clamped01) * 255 + 0.5)
            let b = UInt32((blue.clamped01) * 255 + 0.5)
            return (a << 24) | (r << 16) | (g << 8) | b
        }

        public func opacity(_ value: CGFloat) -> RGBA {
            RGBA(red: red, green: green, blue: blue, alpha: alpha * value)
        }
    }

    /// Light appearance variant; `dark` is used when the environment is in dark mode.
    public var light: RGBA
    public var dark: RGBA?

    public init(_ light: RGBA, dark: RGBA? = nil) {
        self.light = light
        self.dark = dark
    }

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat = 1) {
        self.init(RGBA(red: red, green: green, blue: blue, alpha: opacity))
    }

    public init(white: CGFloat, opacity: CGFloat = 1) {
        self.init(RGBA(white: white, alpha: opacity))
    }

    public init(hex: UInt32, opacity: CGFloat = 1) {
        self.init(RGBA(hex: hex, alpha: opacity))
    }

    // A color that adapts to the color scheme.
    public init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    public func opacity(_ value: CGFloat) -> Color {
        Color(light.opacity(value), dark: dark?.opacity(value))
    }

    public func resolve(isDark: Bool) -> RGBA {
        isDark ? (dark ?? light) : light
    }

    // MARK: System palette (iOS system colors, which is what SwiftUI source expects)

    public static let clear = Color(RGBA(red: 0, green: 0, blue: 0, alpha: 0))
    public static let black = Color(RGBA(white: 0))
    public static let white = Color(RGBA(white: 1))
    public static let gray = Color(
        RGBA(hex: 0x8E8E93),
        dark: RGBA(hex: 0x8E8E93)
    )
    public static let red = Color(RGBA(hex: 0xFF3B30), dark: RGBA(hex: 0xFF453A))
    public static let orange = Color(RGBA(hex: 0xFF9500), dark: RGBA(hex: 0xFF9F0A))
    public static let yellow = Color(RGBA(hex: 0xFFCC00), dark: RGBA(hex: 0xFFD60A))
    public static let green = Color(RGBA(hex: 0x34C759), dark: RGBA(hex: 0x30D158))
    public static let mint = Color(RGBA(hex: 0x00C7BE), dark: RGBA(hex: 0x63E6E2))
    public static let teal = Color(RGBA(hex: 0x30B0C7), dark: RGBA(hex: 0x40C8E0))
    public static let cyan = Color(RGBA(hex: 0x32ADE6), dark: RGBA(hex: 0x64D2FF))
    public static let blue = Color(RGBA(hex: 0x007AFF), dark: RGBA(hex: 0x0A84FF))
    public static let indigo = Color(RGBA(hex: 0x5856D6), dark: RGBA(hex: 0x5E5CE6))
    public static let purple = Color(RGBA(hex: 0xAF52DE), dark: RGBA(hex: 0xBF5AF2))
    public static let pink = Color(RGBA(hex: 0xFF2D55), dark: RGBA(hex: 0xFF375F))
    public static let brown = Color(RGBA(hex: 0xA2845E), dark: RGBA(hex: 0xAC8E68))

    // Semantic colors, light/dark pairs like UIKit's dynamic system colors.
    public static let primary = Color(RGBA(hex: 0x000000), dark: RGBA(hex: 0xFFFFFF))
    public static let secondary = Color(
        RGBA(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.6),
        dark: RGBA(red: 0.922, green: 0.922, blue: 0.961, alpha: 0.6)
    )
    public static let tertiary = Color(
        RGBA(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.3),
        dark: RGBA(red: 0.922, green: 0.922, blue: 0.961, alpha: 0.3)
    )
    /// The grouped background used by list/scroll containers.
    public static let systemGroupedBackground = Color(RGBA(hex: 0xF2F2F7), dark: RGBA(hex: 0x000000))
    public static let secondarySystemGroupedBackground = Color(RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x1C1C1E))
    public static let systemBackground = Color(RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x000000))
    public static let secondarySystemBackground = Color(RGBA(hex: 0xF2F2F7), dark: RGBA(hex: 0x1C1C1E))
    public static let tertiarySystemBackground = Color(RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x2C2C2E))
    public static let separator = Color(
        RGBA(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.29),
        dark: RGBA(red: 0.329, green: 0.329, blue: 0.345, alpha: 0.6)
    )
    public static let label = primary
    public static let secondaryLabel = secondary
}

extension CGFloat {
    var clamped01: CGFloat { sClamp(self, 0, 1) }
}

// MARK: - ShapeStyle

public protocol ShapeStyle {}

extension Color: ShapeStyle {}

// MARK: - Gradient

public struct Gradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: Color
        public var location: CGFloat

        public init(color: Color, location: CGFloat) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]

    public init(stops: [Stop]) {
        self.stops = stops
    }

    public init(colors: [Color]) {
        if colors.count <= 1 {
            self.stops = colors.map { Stop(color: $0, location: 0) }
        } else {
            let step = 1 / CGFloat(colors.count - 1)
            self.stops = colors.enumerated().map { index, color in
                Stop(color: color, location: CGFloat(index) * step)
            }
        }
    }
}

public struct LinearGradient: ShapeStyle, Hashable {
    public var gradient: Gradient
    public var startPoint: UnitPoint
    public var endPoint: UnitPoint

    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }

    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint)
    }
}

public struct RadialGradient: ShapeStyle, Hashable {
    public var gradient: Gradient
    public var center: UnitPoint
    public var startRadius: CGFloat
    public var endRadius: CGFloat

    public init(gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.gradient = gradient
        self.center = center
        self.startRadius = startRadius
        self.endRadius = endRadius
    }
}

/// Type-erased style so the node tree can carry any `ShapeStyle`.
public enum AnyShapeStyle: Hashable {
    case color(Color)
    case linearGradient(LinearGradient)
    case radialGradient(RadialGradient)

    public init(_ style: some ShapeStyle) {
        if let color = style as? Color {
            self = .color(color)
        } else if let gradient = style as? LinearGradient {
            self = .linearGradient(gradient)
        } else if let gradient = style as? RadialGradient {
            self = .radialGradient(gradient)
        } else {
            self = .color(.primary)
        }
    }
}

// MARK: - Font

public struct Font: Hashable, Sendable {
    public enum Weight: Int, Hashable, Sendable, CaseIterable {
        case ultraLight = 100
        case thin = 200
        case light = 300
        case regular = 400
        case medium = 500
        case semibold = 600
        case bold = 700
        case heavy = 800
        case black = 900
    }

    public enum Design: Hashable, Sendable {
        case `default`, serif, rounded, monospaced
    }

    public var size: CGFloat
    public var weight: Weight
    public var design: Design
    public var italic: Bool
    /// When true the size is the system body size and respects accessibility scaling.
    public var isTextStyle: Bool

    public init(size: CGFloat, weight: Weight = .regular, design: Design = .default, italic: Bool = false) {
        self.size = size
        self.weight = weight
        self.design = design
        self.italic = italic
        self.isTextStyle = false
    }

    public static func system(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        Font(size: size, weight: weight, design: design)
    }

    public static func system(_ style: TextStyle, design: Design = .default, weight: Weight? = nil) -> Font {
        var font = Font(size: style.defaultSize, weight: weight ?? style.defaultWeight, design: design)
        font.isTextStyle = true
        return font
    }

    public func weight(_ weight: Weight) -> Font {
        var copy = self
        copy.weight = weight
        return copy
    }

    public func bold() -> Font { weight(.bold) }

    public func italic() -> Font {
        var copy = self
        copy.italic = true
        return copy
    }

    public func monospaced() -> Font {
        var copy = self
        copy.design = .monospaced
        return copy
    }

    public func system(size: CGFloat) -> Font {
        var copy = self
        copy.size = size
        return copy
    }

    // Text styles, matching iOS values.
    public static let largeTitle = Font.system(.largeTitle)
    public static let title = Font.system(.title)
    public static let title2 = Font.system(.title2)
    public static let title3 = Font.system(.title3)
    public static let headline = Font.system(.headline)
    public static let subheadline = Font.system(.subheadline)
    public static let body = Font.system(.body)
    public static let callout = Font.system(.callout)
    public static let footnote = Font.system(.footnote)
    public static let caption = Font.system(.caption)
    public static let caption2 = Font.system(.caption2)
}

public enum TextStyle: Hashable, Sendable, CaseIterable {
    case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2

    public var defaultSize: CGFloat {
        switch self {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .subheadline: return 15
        case .body: return 17
        case .callout: return 16
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        }
    }

    public var defaultWeight: Font.Weight {
        switch self {
        case .headline: return .semibold
        default: return .regular
        }
    }
}
