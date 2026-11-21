// CoreGraphics — platform shim for the Android port.
//
// WHY THIS IS A SHIM, NOT A RETARGETED INTERFACE
// ----------------------------------------------
// Apple's CoreGraphics.framework does ship a textual module interface, but every
// declaration in it is an *extension* on a type that the Clang module
// (`CoreGraphics/*.h`) produces (`CGColor`, `CGContext`, `CGPath`, ...), or a
// Swift-level convenience over one (`CGAffineTransform.concatenating`, ...).
// There is no Clang importer on Android, so those base declarations cannot be
// reproduced by retargeting; the type declarations have to exist as Swift source.
//
// Declarations below are copied from Apple's shipped headers and interfaces:
//   * System/Library/Frameworks/CoreFoundation.framework/Headers/CFCGTypes.h
//       CGFloat, CGPoint, CGSize, CGRect, CGVector, CGAffineTransform
//   * System/Library/Frameworks/CoreGraphics.framework/Headers/{CGColor,CGContext,
//       CGImage,CGPath}.h  and  Modules/CoreGraphics.swiftmodule/
//       arm64-apple-ios-simulator.swiftinterface  (the Swift overlay members)
//
// WHAT IS DIFFERENT FROM DARWIN (intentional, documented in docs/PORT-SDK.md)
// --------------------------------------------------------------------------
// * `CGFloat` / `CGPoint` / `CGSize` / `CGRect` are declared in
//   CoreFoundation/CFCGTypes.h on Darwin; on Android the corelibs `Foundation`
//   module already declares them (with full `BinaryFloatingPoint` / geometry
//   implementations), so they are re-exported as type aliases rather than
//   re-declared. Only the *module* they are reachable through changes.
// * CG class types are ordinary Swift classes: there is no Core Foundation /
//   ObjC object runtime on Android.
//
// FATALERROR POLICY
// -----------------
// Everything below is a *declaration*, never an implementation. Bodies are
// `fatalError()` placeholders on purpose: this module only has to make Apple's
// retargeted SwiftUI interface compile, and the real geometry/raster behaviour is
// implemented by the Android runtime target, which replaces these entry points.
import Foundation

// MARK: - Foundation geometry (declared in CoreFoundation/CFCGTypes.h on Darwin)

public typealias CGFloat = Foundation.CGFloat
public typealias CGPoint = Foundation.CGPoint
public typealias CGSize = Foundation.CGSize
public typealias CGRect = Foundation.CGRect

// MARK: - CGVector  (CFCGTypes.h)

public struct CGVector: Equatable, Hashable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init() { fatalError() }

    public init(dx: CGFloat, dy: CGFloat) { fatalError() }

    public static let zero = CGVector(dx: 0, dy: 0)
}

// MARK: - CGAffineTransform  (CFCGTypes.h + CoreGraphics Swift overlay)

public struct CGAffineTransformComponents: Equatable, Hashable, Sendable {
    public var scale: CGSize
    public var horizontalShear: CGFloat
    public var rotation: CGFloat
    public var translation: CGVector

    public init() { fatalError() }

    public init(scale: CGSize = .init(width: 1, height: 1), horizontalShear: CGFloat = 0,
                rotation: CGFloat = 0, translation: CGVector = .zero) { fatalError() }
}

public struct CGAffineTransform: Equatable, Hashable, Sendable {
    public var a: CGFloat
    public var b: CGFloat
    public var c: CGFloat
    public var d: CGFloat
    public var tx: CGFloat
    public var ty: CGFloat

    public init() { fatalError() }

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) { fatalError() }

    public init(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ tx: CGFloat, _ ty: CGFloat) { fatalError() }

    public init(translationX tx: CGFloat, y ty: CGFloat) { fatalError() }

    public init(scaleX sx: CGFloat, y sy: CGFloat) { fatalError() }

    public init(rotationAngle angle: CGFloat) { fatalError() }

    public init(_ components: CGAffineTransformComponents) { fatalError() }

    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public var isIdentity: Bool { fatalError() }

    public func translatedBy(x tx: CGFloat, y ty: CGFloat) -> CGAffineTransform { fatalError() }

    public func scaledBy(x sx: CGFloat, y sy: CGFloat) -> CGAffineTransform { fatalError() }

    public func rotated(by angle: CGFloat) -> CGAffineTransform { fatalError() }

    public func inverted() -> CGAffineTransform { fatalError() }

    public func decomposed() -> CGAffineTransformComponents { fatalError() }

    public func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform { fatalError() }
}

// MARK: - CGColor  (CGColor.h + CoreGraphics Swift overlay)

public class CGColor: Hashable, @unchecked Sendable {
    public init(_colorLiteralRed red: Float, green: Float, blue: Float, alpha: Float) { fatalError() }

    public var components: [CGFloat]? { fatalError() }

    public var alpha: CGFloat { fatalError() }

    public static func == (lhs: CGColor, rhs: CGColor) -> Bool { fatalError() }

    public func hash(into hasher: inout Hasher) { fatalError() }
}

// MARK: - CGContext  (CGContext.h)

public class CGContext: @unchecked Sendable {
}

// MARK: - CGImage  (CGImage.h)

public class CGImage: Hashable, @unchecked Sendable {
    public var width: Int { fatalError() }

    public var height: Int { fatalError() }

    public static func == (lhs: CGImage, rhs: CGImage) -> Bool { fatalError() }

    public func hash(into hasher: inout Hasher) { fatalError() }
}

// MARK: - CGPath / CGMutablePath  (CGPath.h)

public class CGPath: Hashable, @unchecked Sendable {
    public var isEmpty: Bool { fatalError() }

    public static func == (lhs: CGPath, rhs: CGPath) -> Bool { fatalError() }

    public func hash(into hasher: inout Hasher) { fatalError() }
}

public class CGMutablePath: CGPath {
}

// MARK: - CGLineCap / CGLineJoin  (CGPath.h)

public enum CGLineCap: Int32, Sendable {
    case butt
    case round
    case square
}

public enum CGLineJoin: Int32, Sendable {
    case miter
    case round
    case bevel
}

/// `CGBlendMode` — case set and raw values copied from CoreGraphics' `CGContext.h`
/// (`typedef CF_ENUM(int32_t, CGBlendMode)`), in Apple's declaration order.
public struct CGBlendMode: RawRepresentable, Equatable, Hashable, Sendable {
    public var rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let normal = CGBlendMode(rawValue: 0)
    public static let multiply = CGBlendMode(rawValue: 1)
    public static let screen = CGBlendMode(rawValue: 2)
    public static let overlay = CGBlendMode(rawValue: 3)
    public static let darken = CGBlendMode(rawValue: 4)
    public static let lighten = CGBlendMode(rawValue: 5)
    public static let colorDodge = CGBlendMode(rawValue: 6)
    public static let colorBurn = CGBlendMode(rawValue: 7)
    public static let softLight = CGBlendMode(rawValue: 8)
    public static let hardLight = CGBlendMode(rawValue: 9)
    public static let difference = CGBlendMode(rawValue: 10)
    public static let exclusion = CGBlendMode(rawValue: 11)
    public static let hue = CGBlendMode(rawValue: 12)
    public static let saturation = CGBlendMode(rawValue: 13)
    public static let color = CGBlendMode(rawValue: 14)
    public static let luminosity = CGBlendMode(rawValue: 15)
    public static let clear = CGBlendMode(rawValue: 16)
    public static let copy = CGBlendMode(rawValue: 17)
    public static let sourceIn = CGBlendMode(rawValue: 18)
    public static let sourceOut = CGBlendMode(rawValue: 19)
    public static let sourceAtop = CGBlendMode(rawValue: 20)
    public static let destinationOver = CGBlendMode(rawValue: 21)
    public static let destinationIn = CGBlendMode(rawValue: 22)
    public static let destinationOut = CGBlendMode(rawValue: 23)
    public static let destinationAtop = CGBlendMode(rawValue: 24)
    public static let xor = CGBlendMode(rawValue: 25)
    public static let plusDarker = CGBlendMode(rawValue: 26)
    public static let plusLighter = CGBlendMode(rawValue: 27)
}
