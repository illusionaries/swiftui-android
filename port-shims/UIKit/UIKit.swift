// UIKit — platform shim for the Android port.
//
// WHY THIS MODULE IS A SHIM
// -------------------------
// UIKit is an Objective-C framework. Apple ships a 7,125-line Swift *overlay*
// (`UIKit.framework/Modules/UIKit.swiftmodule/arm64-apple-ios-simulator.swiftinterface`),
// but every declaration in it is either an extension on an ObjC class from
// `UIKit.framework/Headers/*.h` or a Swift-only helper (like `UITraitBridgedEnvironmentKey`)
// that names those classes. With no Clang importer on Android there is nothing to extend,
// so the framework cannot be retargeted: the types have to exist as Swift source.
//
// SCOPE
// -----
// Exactly the names the retargeted `SwiftUI` interface references — derived mechanically
// with `grep -oE '\bUI[A-Z][A-Za-z]+'` over
// build/port-sdk/gen/SwiftUI.swiftmodule/*.swiftinterface (40 names). SwiftUI's own
// `UIViewRepresentable`, `UIHostingController`, `UIHostingConfiguration`,
// `UIViewControllerRepresentable`, ... are declared by SwiftUI itself and are deliberately
// absent here.
//
// PROVENANCE
// ----------
// Signatures are copied from Apple's shipped artifacts:
//   * value types (UIEdgeInsets, NSUnderlineStyle, UIUserInterfaceStyle, ...) from
//     `UIKit.framework/Headers/*.h` (`NS_ENUM`, `NS_OPTIONS`, `NS_STRUCT` declarations);
//   * protocols (UIContentView, UIContentConfiguration, UITraitBridgedEnvironmentKey, ...)
//     from the overlay interface: UIContentView at line 1199, UIContentConfiguration at
//     line 1207, UITraitBridgedEnvironmentKey at line 2773;
//   * classes only from headers, with the superclass relationships of the headers
//     (`UIView : UIResponder : NSObject`, `UIViewController : UIResponder`, ...).
//
// SEMANTIC GAPS (see docs/PORT-SDK.md)
// ------------------------------------
// * ObjC classes become ordinary Swift classes; `NSObject` is the real corelibs
//   Foundation root class (aliased through the `ObjectiveC` shim).
// * `@MainActor` isolation is not modelled on the shim types: there is one UI thread on
//   Android and the engine owns it. SwiftUI's own `@MainActor` API is unaffected.
// * `UIColor`/`UIImage`/`UIFont` are declaration-faithful but not pixel-faithful: the
//   runtime maps them to `android.graphics.Color`/`Bitmap`/`Typeface`.
//
// FATALERROR POLICY
// -----------------
// This file is declaration-only. Every body traps on purpose: it exists so Apple's real
// SwiftUI interface compiles for Android, and the Android runtime implements the actual
// behaviour in a different target.
public import Foundation
public import ObjectiveC
public import CoreGraphics
public import QuartzCore
public import SwiftUICore

// MARK: - Geometry and option values  (UIKit/UIEdgeInsets.h, UIGeometry.h)

public struct UIEdgeInsets: Hashable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init() { fatalError() }

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) { fatalError() }

    public static let zero = UIEdgeInsets()
}

public struct NSDirectionalEdgeInsets: Hashable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init() { fatalError() }

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) { fatalError() }

    public static let zero = NSDirectionalEdgeInsets()
}

// `NSUnderlineStyle` is declared in Foundation's NSAttributedString.h; SwiftUI spells it
// `UIKit.NSUnderlineStyle` because UIKit re-exports Foundation. Declared here for the
// spelling the interface uses.
public struct NSUnderlineStyle: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let single = NSUnderlineStyle(rawValue: 0x01)
    public static let thick = NSUnderlineStyle(rawValue: 0x02)
    public static let double = NSUnderlineStyle(rawValue: 0x09)
    public static let patternSolid = NSUnderlineStyle(rawValue: 0x0000)
    public static let patternDot = NSUnderlineStyle(rawValue: 0x0100)
    public static let patternDash = NSUnderlineStyle(rawValue: 0x0200)
    public static let patternDashDot = NSUnderlineStyle(rawValue: 0x0300)
    public static let patternDashDotDot = NSUnderlineStyle(rawValue: 0x0400)
    public static let byWord = NSUnderlineStyle(rawValue: 0x8000)
    public static let byCharacter = NSUnderlineStyle(rawValue: 0x10000)
}

// MARK: - Enumerations  (UIKit/*.h NS_ENUM declarations)

public enum UIUserInterfaceStyle: Int, Sendable {
    case unspecified = 0
    case light = 1
    case dark = 2
}

public enum UIUserInterfaceSizeClass: Int, Sendable {
    case unspecified = 0
    case compact = 1
    case regular = 2
}

public enum UITraitEnvironmentLayoutDirection: Int, Sendable {
    case unspecified = -1
    case leftToRight = 0
    case rightToLeft = 1
}

public enum UIAccessibilityContrast: Int, Sendable {
    case unspecified = -1
    case normal = 0
    case high = 1
}

public enum UILegibilityWeight: Int, Sendable {
    case unspecified = -1
    case regular = 0
    case bold = 1
}

public enum UIStatusBarStyle: Int, Sendable {
    case `default` = 0
    case lightContent = 1
    case darkContent = 3
}

public enum UIStatusBarAnimation: Int, Sendable {
    case none = 0
    case fade = 1
    case slide = 2
}

public enum UIKeyboardType: Int, Sendable {
    case `default` = 0
    case asciiCapable = 1
    case numbersAndPunctuation = 2
    case URL = 3
    case numberPad = 4
    case phonePad = 5
    case namePhonePad = 6
    case emailAddress = 7
    case decimalPad = 8
    case twitter = 9
    case webSearch = 10
    case asciiCapableNumberPad = 11
}

public enum UITextAutocapitalizationType: Int, Sendable {
    case none = 0
    case words = 1
    case sentences = 2
    case allCharacters = 3
}

// MARK: - String-backed value types  (UITextInputTraits.h, UIContentSizeCategory.h)

public struct UITextContentType: Hashable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let name = UITextContentType(rawValue: "name")
    public static let emailAddress = UITextContentType(rawValue: "emailAddress")
    public static let telephoneNumber = UITextContentType(rawValue: "telephoneNumber")
    public static let URL = UITextContentType(rawValue: "URL")
    public static let password = UITextContentType(rawValue: "password")
    public static let newPassword = UITextContentType(rawValue: "newPassword")
    public static let oneTimeCode = UITextContentType(rawValue: "oneTimeCode")
}

public struct UIContentSizeCategory: Hashable, RawRepresentable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let extraSmall = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryXS")
    public static let small = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryS")
    public static let medium = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryM")
    public static let large = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryL")
    public static let extraLarge = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryXL")
    public static let extraExtraLarge = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryXXL")
    public static let extraExtraExtraLarge = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryXXXL")
    public static let accessibilityMedium = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryAccessibilityM")
    public static let accessibilityLarge = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryAccessibilityL")
    public static let accessibilityExtraLarge = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryAccessibilityXL")
    public static let accessibilityExtraExtraLarge = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryAccessibilityXXL")
    public static let accessibilityExtraExtraExtraLarge = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryAccessibilityXXXL")

    public static func < (lhs: UIContentSizeCategory, rhs: UIContentSizeCategory) -> Bool { fatalError() }
}

// MARK: - Protocols  (overlay interface lines 1199-1215, 2773; UIKit headers)

public protocol UIConfigurationState: NSObjectProtocol {
}

public protocol UIContentConfiguration {
    @MainActor func makeContentView() -> any UIView & UIContentView

    func updated(for state: any UIConfigurationState) -> Self
}

public protocol UIContentView: NSObjectProtocol {
    @MainActor var configuration: any UIContentConfiguration { get set }

    @MainActor func supports(_ configuration: any UIContentConfiguration) -> Bool
}

extension UIContentView {
    @MainActor public func supports(_ configuration: any UIContentConfiguration) -> Bool { fatalError() }
}

public protocol UIContentContainer: NSObjectProtocol {
}

public protocol UIFocusEnvironment: NSObjectProtocol {
}

public protocol UIFocusItem: UIFocusEnvironment {
}

public protocol UIDragSession: NSObjectProtocol {
}

public protocol UIDropSession: UIDragSession {
}

public protocol UIApplicationDelegate: NSObjectProtocol {
}

public protocol UISceneDelegate: NSObjectProtocol {
}

public protocol UIViewControllerTransitionCoordinator: NSObjectProtocol {
}

public protocol UIMutableTraits {
}

/// `UITraitBridgedEnvironmentKey` — overlay interface line 2773:
/// `public protocol UITraitBridgedEnvironmentKey : SwiftUICore.EnvironmentKey`.
public protocol UITraitBridgedEnvironmentKey: SwiftUICore.EnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> Self.Value

    static func write(to mutableTraits: inout any UIMutableTraits, value: Self.Value)
}

// MARK: - Classes  (UIKit headers; superclasses as declared there)

open class UIResponder: NSObject {
    public override init() { fatalError() }

    public required init?(coder: NSCoder) { fatalError() }
}

open class UIView: UIResponder {
    public var frame: CGRect
    public var bounds: CGRect
    public var backgroundColor: UIColor?
    public var layer: CALayer
    public var isUserInteractionEnabled: Bool

    public override init() { fatalError() }

    public init(frame: CGRect) { fatalError() }

    public required init?(coder: NSCoder) { fatalError() }

    open func addSubview(_ view: UIView) { fatalError() }

    open func removeFromSuperview() { fatalError() }

    open func layoutIfNeeded() { fatalError() }

    open func setNeedsLayout() { fatalError() }

    open func sizeThatFits(_ size: CGSize) -> CGSize { fatalError() }
}

open class UIViewController: UIResponder {
    public var view: UIView

    public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) { fatalError() }

    public required init?(coder: NSCoder) { fatalError() }

    open func loadView() { fatalError() }

    open func viewDidLoad() { fatalError() }

    open func present(_ viewControllerToPresent: UIViewController, animated flag: Bool,
                      completion: (() -> Void)? = nil) { fatalError() }
}

open class UIColor: NSObject, @unchecked Sendable {
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { fatalError() }

    public init(white: CGFloat, alpha: CGFloat) { fatalError() }

    public init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) { fatalError() }

    public var cgColor: CGColor { fatalError() }

    public static let clear = UIColor(white: 0, alpha: 0)
    public static let black = UIColor(white: 0, alpha: 1)
    public static let white = UIColor(white: 1, alpha: 1)
    public static let gray = UIColor(white: 0.5, alpha: 1)
    public static let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
    public static let green = UIColor(red: 0, green: 1, blue: 0, alpha: 1)
    public static let blue = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
    public static let label = UIColor(white: 0, alpha: 1)
    public static let secondaryLabel = UIColor(white: 0.5, alpha: 1)
    public static let systemBackground = UIColor(white: 1, alpha: 1)
}

open class UIImage: NSObject, @unchecked Sendable {
    public enum Orientation: Int, Sendable {
        case up = 0
        case down = 1
        case left = 2
        case right = 3
        case upMirrored = 4
        case downMirrored = 5
        case leftMirrored = 6
        case rightMirrored = 7
    }

    public init(cgImage: CGImage, scale: CGFloat, orientation: UIImage.Orientation) { fatalError() }

    public var size: CGSize { fatalError() }

    public var scale: CGFloat { fatalError() }

    public var cgImage: CGImage? { fatalError() }
}

open class UIEvent: NSObject {
}

open class UIGestureRecognizer: NSObject {
}

open class UIKeyCommand: NSObject {
}

open class UIFocusUpdateContext: NSObject {
}

open class UIFocusAnimationCoordinator: NSObject {
}

open class UISceneSessionActivationRequest: NSObject {
}

open class UITraitCollection: NSObject, @unchecked Sendable {
    public var userInterfaceStyle: UIUserInterfaceStyle { fatalError() }

    public var userInterfaceIdiom: Int { fatalError() }

    public var displayScale: CGFloat { fatalError() }
}
