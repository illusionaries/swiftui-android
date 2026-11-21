// DisplayList.swift — the renderer-agnostic output of the port.
//
// The engine walks its node tree and emits a flat list of absolute-coordinate drawing
// commands in *points* (dp). A backend replays them; on Android that backend is
// AndroidCanvasPainter, which forwards each command to the C bridge and from there to
// android.graphics.Canvas (Skia). Keeping this layer free of platform types is what lets
// the same code be unit-tested on the host and salvaged if a second backend is added.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

public enum DisplayCommand: Equatable {
    case save
    case restore
    case clip(CGRect, cornerRadius: CGFloat)
    case fillRect(CGRect, RGBAColor)
    case fillRoundRect(CGRect, cornerRadius: CGFloat, RGBAColor)
    case fillOval(CGRect, RGBAColor)
    case strokeRect(CGRect, width: CGFloat, RGBAColor)
    case strokeRoundRect(CGRect, cornerRadius: CGFloat, width: CGFloat, RGBAColor)
    case line(CGPoint, CGPoint, width: CGFloat, RGBAColor)
    case fillPath(PathData, RGBAColor)
    case strokePath(PathData, width: CGFloat, RGBAColor)
    case text(String, origin: CGPoint, style: TextStyleDescriptor)
    case shadowRoundRect(CGRect, cornerRadius: CGFloat, dx: CGFloat, dy: CGFloat, blur: CGFloat, RGBAColor)
    case linearGradient(CGRect, cornerRadius: CGFloat, start: CGPoint, end: CGPoint, stops: [RGBAColor])
}

/// Straight sRGB color, ready to hand to the backend as 0xAARRGGBB.
public struct RGBAColor: Equatable, Hashable {
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

    public init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public init(white: CGFloat, alpha: CGFloat = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public var argb: UInt32 {
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(1, v)) * 255 + 0.5) }
        return (byte(alpha) << 24) | (byte(red) << 16) | (byte(green) << 8) | byte(blue)
    }

    public func withAlpha(_ value: CGFloat) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha * value)
    }

    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
}

/// Font description carried by a text command. `size` is in points (dp).
public struct TextStyleDescriptor: Equatable, Hashable {
    public enum Weight: Int, Equatable, Hashable {
        case ultraLight = 100, thin = 200, light = 300, regular = 400
        case medium = 500, semibold = 600, bold = 700, heavy = 800, black = 900
    }

    public var size: CGFloat
    public var weight: Weight
    public var italic: Bool
    public var color: RGBAColor
    public var letterSpacing: CGFloat

    public init(size: CGFloat, weight: Weight = .regular, italic: Bool = false,
                color: RGBAColor = .black, letterSpacing: CGFloat = 0) {
        self.size = size
        self.weight = weight
        self.italic = italic
        self.color = color
        self.letterSpacing = letterSpacing
    }
}

/// Immutable path description in the same command encoding the C bridge consumes.
public struct PathData: Equatable, Hashable {
    public enum Element: Equatable, Hashable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quad(control: CGPoint, to: CGPoint)
        case cubic(c1: CGPoint, c2: CGPoint, to: CGPoint)
        case close
    }

    public var elements: [Element]

    public init(elements: [Element] = []) {
        self.elements = elements
    }

    public mutating func move(to point: CGPoint) { elements.append(.move(to: point)) }
    public mutating func addLine(to point: CGPoint) { elements.append(.line(to: point)) }
    public mutating func addQuad(control: CGPoint, to point: CGPoint) { elements.append(.quad(control: control, to: point)) }
    public mutating func addCubic(_ c1: CGPoint, _ c2: CGPoint, to point: CGPoint) { elements.append(.cubic(c1: c1, c2: c2, to: point)) }
    public mutating func closeSubpath() { elements.append(.close) }

    /// Packs into the float stream documented in AndroidBridge.h.
    public func encoded() -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(elements.count * 7)
        for element in elements {
            switch element {
            case let .move(point):
                out += [0, Float(point.x), Float(point.y)]
            case let .line(point):
                out += [1, Float(point.x), Float(point.y)]
            case let .quad(control, point):
                out += [2, Float(control.x), Float(control.y), Float(point.x), Float(point.y)]
            case let .cubic(c1, c2, point):
                out += [3, Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y), Float(point.x), Float(point.y)]
            case .close:
                out += [4]
            }
        }
        return out
    }

    public static func roundedRect(_ rect: CGRect, cornerRadius: CGFloat) -> PathData {
        PathData.shapes.roundedRect(rect, cornerRadius: cornerRadius)
    }

    public enum shapes {
        public static func roundedRect(_ rect: CGRect, cornerRadius: CGFloat) -> PathData {
            let r = min(cornerRadius, min(rect.width, rect.height) / 2)
            guard r > 0 else {
                return PathData(elements: [
                    .move(to: CGPoint(x: rect.minX, y: rect.minY)),
                    .line(to: CGPoint(x: rect.maxX, y: rect.minY)),
                    .line(to: CGPoint(x: rect.maxX, y: rect.maxY)),
                    .line(to: CGPoint(x: rect.minX, y: rect.maxY)),
                    .close,
                ])
            }
            let k: CGFloat = 0.5522847498 * r
            var path = PathData()
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addCubic(CGPoint(x: rect.maxX - r + k, y: rect.minY),
                          CGPoint(x: rect.maxX, y: rect.minY + r - k),
                          to: CGPoint(x: rect.maxX, y: rect.minY + r))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addCubic(CGPoint(x: rect.maxX, y: rect.maxY - r + k),
                          CGPoint(x: rect.maxX - r + k, y: rect.maxY),
                          to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addCubic(CGPoint(x: rect.minX + r - k, y: rect.maxY),
                          CGPoint(x: rect.minX, y: rect.maxY - r + k),
                          to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addCubic(CGPoint(x: rect.minX, y: rect.minY + r - k),
                          CGPoint(x: rect.minX + r - k, y: rect.minY),
                          to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.closeSubpath()
            return path
        }

        public static func circle(_ rect: CGRect) -> PathData {
            PathData.shapes.oval(rect)
        }

        public static func oval(_ rect: CGRect) -> PathData {
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2, ry = rect.height / 2
            let kx = 0.5522847498 * rx, ky = 0.5522847498 * ry
            var path = PathData()
            path.move(to: CGPoint(x: cx, y: rect.minY))
            path.addCubic(CGPoint(x: cx + kx, y: rect.minY), CGPoint(x: rect.maxX, y: cy - ky), to: CGPoint(x: rect.maxX, y: cy))
            path.addCubic(CGPoint(x: rect.maxX, y: cy + ky), CGPoint(x: cx + kx, y: rect.maxY), to: CGPoint(x: cx, y: rect.maxY))
            path.addCubic(CGPoint(x: cx - kx, y: rect.maxY), CGPoint(x: rect.minX, y: cy + ky), to: CGPoint(x: rect.minX, y: cy))
            path.addCubic(CGPoint(x: rect.minX, y: cy - ky), CGPoint(x: cx - kx, y: rect.minY), to: CGPoint(x: cx, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }
}

public struct DisplayList: Equatable {
    public var commands: [DisplayCommand] = []
    public var bounds: CGRect = .zero

    public init() {}

    public mutating func append(_ command: DisplayCommand) {
        commands.append(command)
    }
}

/// Anything the renderer can replay a display list for.
public protocol DisplayListPainter {
    /// Width of `text` in points with the given style, for a single line.
    func measureText(_ text: String, style: TextStyleDescriptor) -> CGFloat
    /// Ascent (negative, above baseline), descent, leading in points.
    func fontMetrics(style: TextStyleDescriptor) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat)
    func paint(_ list: DisplayList)
}
