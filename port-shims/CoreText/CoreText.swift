// CoreText — platform shim for the Android port.
//
// Apple's CoreText ships a 112-line Swift interface
// (`CoreText.framework/Modules/CoreText.swiftmodule/arm64-apple-ios-simulator.swiftinterface`),
// but it consists solely of extensions on Foundation types plus *Clang* types that only
// exist through `CoreText.framework/Headers/CTFont.h` (`CTFont`). Without a Clang importer
// the module cannot be retargeted; the declarations below are copied from that interface
// (and `CTFont.h` for `CTFont`), restricted to what SwiftUI/SwiftUICore reference.
//
// Referenced by the retargeted interfaces:
//   * `CoreText.CTFont` — `CTFont.h` (`@interface CTFont`), used by
//     `SwiftUICore.Font.Resolved.ctFont`.
//   * `AttributedString.LineHeight` + `AttributeScopes.CoreTextAttributes.LineHeightAttribute`
//     — CoreText interface lines 31-119.
//   * `AttributedString.AdaptiveImageGlyph` — CoreText interface lines 60-75.
//   * `AttributeScopes.CoreTextAttributes` — CoreText interface lines 78-82.
//
// Bodies are `fatalError()` placeholders: text shaping on Android goes through
// `android.graphics.Paint`/`Typeface` in the engine's bridge, never through CoreText.
public import Foundation
public import UniformTypeIdentifiers

// MARK: - CTFont  (CoreText/CTFont.h)

open class CTFont: NSObject {
    public override init() { fatalError() }
}

// MARK: - AttributedString.LineHeight  (CoreText swiftinterface line 31)

extension AttributedString {
    public struct LineHeight: Codable, Hashable, Sendable {
        public static var variable: AttributedString.LineHeight { fatalError() }

        public static var normal: AttributedString.LineHeight { fatalError() }

        public static var tight: AttributedString.LineHeight { fatalError() }

        public static var loose: AttributedString.LineHeight { fatalError() }

        public static func multiple(factor: CGFloat) -> AttributedString.LineHeight { fatalError() }

        public static func leading(increase: CGFloat) -> AttributedString.LineHeight { fatalError() }

        public static func exact(points: CGFloat) -> AttributedString.LineHeight { fatalError() }
    }
}

// MARK: - AttributedString.AdaptiveImageGlyph  (CoreText swiftinterface line 60)

extension AttributedString {
    public struct AdaptiveImageGlyph: Codable, Hashable, Equatable, Sendable {
        public init(imageContent: Data) { fatalError() }

        public let imageContent: Data

        public let contentIdentifier: String

        public let contentDescription: String

        public static var contentType: UTType { fatalError() }
    }
}

// MARK: - AttributedString.TextAlignment  (CoreText swiftinterface line 96)

extension AttributedString {
    public enum TextAlignment: CaseIterable, Codable, Hashable, Sendable {
        case left
        case center
        case right
    }
}

// MARK: - AttributeScopes.CoreTextAttributes  (CoreText swiftinterface line 78)

extension AttributeScopes {
    public struct CoreTextAttributes: AttributeScope {
        public init() { fatalError() }
    }
}

extension AttributeScopes.CoreTextAttributes {
    public enum LineHeightAttribute: AttributedStringKey {
        public typealias Value = AttributedString.LineHeight

        public static let name: String = "LineHeight"

        public static let runBoundaries: AttributedString.AttributeRunBoundaries? = nil
    }

    public enum TextAlignmentAttribute: CodableAttributedStringKey {
        public typealias Value = AttributedString.TextAlignment

        public static let name: String = "TextAlignment"

        public static let runBoundaries: AttributedString.AttributeRunBoundaries? = nil
    }
}
