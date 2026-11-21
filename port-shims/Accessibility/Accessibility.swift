// Accessibility — platform shim for the Android port.
//
// Apple ships a 414-line Swift interface for Accessibility, but every declaration in it
// extends an ObjC class from `Accessibility.framework/Headers` (`AXChartDescriptor`,
// `AXBrailleMap`, `AXNumericDataAxisDescriptor`, ...). There is no Clang importer on
// Android, so the module cannot be retargeted as a whole.
//
// The retargeted SwiftUI/SwiftUICore interfaces reference exactly three things:
//
//   Accessibility.AXChartDescriptor                     — accessibility chart API
//                                                        (AXCustomContent.h / AXChartDescriptor.h);
//                                                        used only as a parameter/return type by
//                                                        `AXChartDescriptorRepresentable`.
//   Accessibility.AXCustomContent (+ .Importance)       — AXCustomContent.h:20-49;
//                                                        SwiftUI references the nested
//                                                        `Importance` enum (`NS_SWIFT_NAME` in
//                                                        the header is exactly
//                                                        `AXCustomContent.Importance`).
//   Foundation.AttributeScopes.AccessibilityAttributes  — the `AttributeScope` that the
//                                                        Accessibility overlay injects into
//                                                        `AttributeScopes` (interface line 54).
//                                                        SwiftUICore only stores it as a value
//                                                        inside `SwiftUIAttributes`.
//
// This is the same split Apple uses: an ObjC class with a Swift-side nested enum, plus a
// Swift-only `AttributeScope`. Bodies are `fatalError()` placeholders: Android exposes
// accessibility through its own `AccessibilityNodeInfo` tree, which the runtime will
// bridge in the engine target, not here.
public import Foundation

// MARK: - AXChartDescriptor  (AXChartDescriptor.h)

open class AXChartDescriptor: NSObject {
    public override init() { fatalError() }
}

// MARK: - AXCustomContent  (AXCustomContent.h:20-49, including the nested Importance enum)

open class AXCustomContent: NSObject {
    public enum Importance: UInt, @unchecked Sendable {
        case `default`
        case high

        public init?(rawValue: UInt) { fatalError() }
    }

    public static func customContent(label: String, value: String) -> AXCustomContent { fatalError() }

    public static func customContent(attributedLabel: NSAttributedString, attributedValue: NSAttributedString) -> AXCustomContent { fatalError() }

    public var label: String { fatalError() }

    public var attributedLabel: NSAttributedString { fatalError() }

    public var value: String { fatalError() }

    public var attributedValue: NSAttributedString { fatalError() }

    public var importance: Importance { fatalError() }
}

// MARK: - AttributeScopes.AccessibilityAttributes  (Accessibility swiftinterface line 54)

extension AttributeScopes {
    public struct AccessibilityAttributes: AttributeScope {
        public init() { fatalError() }
    }
}
