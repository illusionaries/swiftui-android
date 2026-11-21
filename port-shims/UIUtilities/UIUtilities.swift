// UIUtilities — platform shim for the Android port.
//
// `UIUtilities` is a Clang *submodule* of UIKit (`UIKit.framework/Headers/UIUtilities.h`)
// that declares `UIRectEdge`. Apple's SwiftUI interface spells the type
// `UIUtilities.UIRectEdge` (see `preferredScreenEdgesDeferringSystemGestures`), so the port
// provides it as its own module, mirroring the submodule name.
//
// Declaration copied from UIKit/UIUtilities.h:
//   typedef NS_OPTIONS(NSUInteger, UIRectEdge) { UIRectEdgeNone = 0,
//       UIRectEdgeTop = 1 << 0, UIRectEdgeLeft = 1 << 1, UIRectEdgeBottom = 1 << 2,
//       UIRectEdgeRight = 1 << 3, UIRectEdgeAll = UIRectEdgeTop | UIRectEdgeLeft |
//       UIRectEdgeBottom | UIRectEdgeRight };
public import Foundation

public struct UIRectEdge: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let none = UIRectEdge(rawValue: 0)
    public static let top = UIRectEdge(rawValue: 1 << 0)
    public static let left = UIRectEdge(rawValue: 1 << 1)
    public static let bottom = UIRectEdge(rawValue: 1 << 2)
    public static let right = UIRectEdge(rawValue: 1 << 3)
    public static let all: UIRectEdge = [.top, .left, .bottom, .right]
}
