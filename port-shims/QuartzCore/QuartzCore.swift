// QuartzCore — platform shim for the Android port.
//
// QuartzCore has no Swift module interface at all (it is a pure ObjC framework); its
// Swift API is whatever ClangImporter makes out of `QuartzCore.framework/Headers`. The
// retargeted SwiftUI interfaces reference exactly two of its types:
//
//   QuartzCore.CALayer       — `@interface CALayer : NSObject <NSSecureCoding,
//                              CAMediaTiming>` (CALayer.h, line 117). SwiftUI uses it only
//                              as a generic constraint / exposed view type
//                              (`_CALayerView<LayerType: CALayer>`), so the declaration is
//                              the class with its designated initializer.
//   QuartzCore.CATransform3D — `struct CATransform3D { CGFloat m11..m44; }`
//                              (CATransform3D.h, line 17) plus the identity constant and the
//                              `isIdentity` accessor from the same header.
//
// On Android there is no Core Animation and no Metal; the runtime will map CALayer
// driven views onto the Android draw pipeline (or report them unsupported). Every body
// is `fatalError()` on purpose: declarations only.
public import Foundation

// MARK: - CATransform3D  (CATransform3D.h)

public struct CATransform3D: Equatable, Hashable, Sendable {
    public var m11: CGFloat
    public var m12: CGFloat
    public var m13: CGFloat
    public var m14: CGFloat
    public var m21: CGFloat
    public var m22: CGFloat
    public var m23: CGFloat
    public var m24: CGFloat
    public var m31: CGFloat
    public var m32: CGFloat
    public var m33: CGFloat
    public var m34: CGFloat
    public var m41: CGFloat
    public var m42: CGFloat
    public var m43: CGFloat
    public var m44: CGFloat

    public init() { fatalError() }

    public init(m11: CGFloat, m12: CGFloat, m13: CGFloat, m14: CGFloat,
                m21: CGFloat, m22: CGFloat, m23: CGFloat, m24: CGFloat,
                m31: CGFloat, m32: CGFloat, m33: CGFloat, m34: CGFloat,
                m41: CGFloat, m42: CGFloat, m43: CGFloat, m44: CGFloat) { fatalError() }

    public static let identity = CATransform3D(
        m11: 1, m12: 0, m13: 0, m14: 0,
        m21: 0, m22: 1, m23: 0, m24: 0,
        m31: 0, m32: 0, m33: 1, m34: 0,
        m41: 0, m42: 0, m43: 0, m44: 1)

    public var isIdentity: Bool { fatalError() }
}

// MARK: - CALayer  (CALayer.h)

open class CALayer: @unchecked Sendable {
    public init() { fatalError() }

    public init(layer: Any) { fatalError() }
}
