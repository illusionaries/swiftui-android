// UIKit — platform shim for the Android port.
//
// WHY THIS MODULE IS A SHIM
// -------------------------
// UIKit is an Objective-C framework. Apple ships a 7,125-line Swift *overlay*
// (`UIKit.framework/Modules/UIKit.swiftmodule/arm64-apple-ios-simulator.swiftinterface`),
// but every declaration in it is either an extension on an ObjC class from
// `UIKit.framework/Headers/*.h` or a Swift-only helper that names those classes. With no
// Clang importer on Android there is nothing to extend, so the framework cannot be
// retargeted: the types have to exist as Swift source.
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
// Class members are exactly those SwiftUI's `_UIHostingView: UIView` and
// `_UIHostingController: UIViewController` overrides (the compiler lists them: `frame`,
// `bounds`, `transform`, `transform3D`, `clipsToBounds`, `safeAreaInsets`,
// `preferredFocusEnvironments`, `viewWillAppear(_:)`, `preferredStatusBarStyle`,
// `hitTest(_:with:)`, ...) plus what the protocols in the overlay require.
//
// PROVENANCE
// ----------
// Signatures are copied from Apple's shipped artifacts:
//   * value types (UIEdgeInsets, NSUnderlineStyle, UIUserInterfaceStyle, ...) from
//     `UIKit.framework/Headers/*.h` (`NS_ENUM` / `NS_OPTIONS` declarations);
//   * protocols UIContentView (overlay line 1199), UIContentConfiguration (line 1207),
//     UITraitBridgedEnvironmentKey (line 2773);
//   * classes and their superclass chain from the headers
//     (`UIView : UIResponder : NSObject`, `UIViewController : UIResponder`, ...).
//
// SEMANTIC GAPS (see docs/PORT-SDK.md)
// ------------------------------------
// * ObjC classes become ordinary Swift classes; `NSObject` is corelibs Foundation's real
//   root class, aliased through the `ObjectiveC` shim.
// * `@MainActor` is modelled on the view/controller hierarchy (as UIKit's
//   `NS_SWIFT_UI_ACTOR` does) but *not* on the leaf value-ish classes
//   (`UIColor`, `UIImage`, `UITraitCollection`), whose isolation is irrelevant on a
//   single-UI-thread platform.
// * `UIColor`/`UIImage` are declaration-faithful but not pixel-faithful: the runtime maps
//   them to `android.graphics.Color` / `Bitmap`.
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
public import UIUtilities
public import FoundationShims

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

// `NSUnderlineStyle` is `NS_OPTIONS` in Foundation's NSAttributedString.h; SwiftUI spells it
// `UIKit.NSUnderlineStyle` because UIKit re-exports Foundation. Declared here for that
// spelling.
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

@MainActor public protocol UIConfigurationState: NSObjectProtocol {
}

public protocol UIContentConfiguration {
    @MainActor func makeContentView() -> any UIView & UIContentView

    func updated(for state: any UIConfigurationState) -> Self
}

@MainActor public protocol UIContentView: NSObjectProtocol {
    var configuration: any UIContentConfiguration { get set }

    func supports(_ configuration: any UIContentConfiguration) -> Bool
}

extension UIContentView {
    @MainActor public func supports(_ configuration: any UIContentConfiguration) -> Bool { fatalError() }
}

@MainActor public protocol UIContentContainer: NSObjectProtocol {
}

@MainActor public protocol UIFocusEnvironment: NSObjectProtocol {
    var preferredFocusEnvironments: [any UIFocusEnvironment] { get }

    func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator)
}

@MainActor public protocol UIFocusItem: UIFocusEnvironment {
}

@MainActor public protocol UIDragSession: NSObjectProtocol {
}

@MainActor public protocol UIDropSession: UIDragSession {
}

@MainActor public protocol UIApplicationDelegate: NSObjectProtocol {
}

@MainActor public protocol UISceneDelegate: NSObjectProtocol {
}

@MainActor public protocol UIViewControllerTransitionCoordinator: NSObjectProtocol {
}

public protocol UIMutableTraits {
}

/// `UITraitBridgedEnvironmentKey` — overlay interface line 2773:
/// `public protocol UITraitBridgedEnvironmentKey : SwiftUICore.EnvironmentKey`.
public protocol UITraitBridgedEnvironmentKey: SwiftUICore.EnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> Self.Value

    static func write(to mutableTraits: inout any UIMutableTraits, value: Self.Value)
}

// MARK: - Classes  (UIKit headers; superclass chain as declared there)

@MainActor open class UIResponder: NSObject {
    public override init() { fatalError() }

    public required init?(coder: NSCoder) { fatalError() }

    open var canBecomeFirstResponder: Bool { fatalError() }

    open var isFirstResponder: Bool { fatalError() }

    open var next: UIResponder? { fatalError() }

    open var keyCommands: [UIKeyCommand]? { fatalError() }

    open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { fatalError() }

    open func target(forAction action: Selector, withSender sender: Any?) -> Any? { fatalError() }

    open var undoManager: FoundationShims.UndoManager? { fatalError() }

    open var accessibilityElements: [Any]? { fatalError() }

    open var automationElements: [Any]? { fatalError() }

    open func accessibilityElementCount() -> Int { fatalError() }

    open func observeValue(forKeyPath keyPath: String?, of object: Any?,
                           change: [FoundationShims.NSKeyValueChangeKey: Any]?,
                           context: UnsafeMutableRawPointer?) { fatalError() }
}

@MainActor open class UIView: UIResponder {
    open var frame: CGRect {
        get { fatalError() }
        set { fatalError() }
    }

    open var bounds: CGRect {
        get { fatalError() }
        set { fatalError() }
    }

    open var contentScaleFactor: CGFloat {
        get { fatalError() }
        set { fatalError() }
    }

    open var backgroundColor: UIColor? {
        get { fatalError() }
        set { fatalError() }
    }

    open var layer: CALayer { fatalError() }

    open var isUserInteractionEnabled: Bool {
        get { fatalError() }
        set { fatalError() }
    }

    open var isHidden: Bool {
        get { fatalError() }
        set { fatalError() }
    }

    open var alpha: CGFloat {
        get { fatalError() }
        set { fatalError() }
    }

    open var transform: CGAffineTransform {
        get { fatalError() }
        set { fatalError() }
    }

    open var transform3D: CATransform3D {
        get { fatalError() }
        set { fatalError() }
    }

    open var clipsToBounds: Bool {
        get { fatalError() }
        set { fatalError() }
    }

    open var safeAreaInsets: UIEdgeInsets { fatalError() }

    open var preferredFocusEnvironments: [any UIFocusEnvironment] { fatalError() }

    public override init() { fatalError() }

    public init(frame: CGRect) { fatalError() }

    public required init?(coder: NSCoder) { fatalError() }

    open func didMoveToWindow() { fatalError() }

    open func layoutSubviews() { fatalError() }

    open func tintColorDidChange() { fatalError() }

    open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { fatalError() }

    open func safeAreaInsetsDidChange() { fatalError() }

    open func didAddSubview(_ subview: UIView) { fatalError() }

    open func willRemoveSubview(_ subview: UIView) { fatalError() }

    open func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { fatalError() }

    open func focusItems(in rect: CGRect) -> [any UIFocusItem] { fatalError() }

    open func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) { fatalError() }

    open func addSubview(_ view: UIView) { fatalError() }

    open func removeFromSuperview() { fatalError() }

    open func layoutIfNeeded() { fatalError() }

    open func setNeedsLayout() { fatalError() }

    open func sizeThatFits(_ size: CGSize) -> CGSize { fatalError() }
}

@MainActor open class UIViewController: UIResponder {
    open var view: UIView { fatalError() }

    open var parent: UIViewController? { fatalError() }

    open var isModalInPresentation: Bool {
        get { fatalError() }
        set { fatalError() }
    }

    open var preferredContentSize: CGSize {
        get { fatalError() }
        set { fatalError() }
    }

    open var preferredStatusBarStyle: UIStatusBarStyle { fatalError() }

    open var prefersStatusBarHidden: Bool { fatalError() }

    open var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { fatalError() }

    open var childForStatusBarStyle: UIViewController? { fatalError() }

    open var childForStatusBarHidden: UIViewController? { fatalError() }

    open var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { fatalError() }

    open var childForScreenEdgesDeferringSystemGestures: UIViewController? { fatalError() }

    open var prefersHomeIndicatorAutoHidden: Bool { fatalError() }

    open var childForHomeIndicatorAutoHidden: UIViewController? { fatalError() }

    public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) { fatalError() }

    public required init?(coder: NSCoder) { fatalError() }

    open func loadView() { fatalError() }

    open func viewDidLoad() { fatalError() }

    open func viewWillAppear(_ animated: Bool) { fatalError() }

    open func viewDidAppear(_ animated: Bool) { fatalError() }

    open func viewWillDisappear(_ animated: Bool) { fatalError() }

    open func viewDidDisappear(_ animated: Bool) { fatalError() }

    open func viewWillLayoutSubviews() { fatalError() }

    open func viewDidLayoutSubviews() { fatalError() }

    open func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) { fatalError() }

    open func willMove(toParent parent: UIViewController?) { fatalError() }

    open func didMove(toParent parent: UIViewController?) { fatalError() }

    open func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) { fatalError() }

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
