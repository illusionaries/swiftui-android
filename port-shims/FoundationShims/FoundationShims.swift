// FoundationShims — the Foundation API that the official Swift SDK for Android does not ship.
//
// WHY THIS MODULE EXISTS
// ----------------------
// The Swift SDK for Android's `Foundation` is a *reduced, dynamically linked,
// non-library-evolution* build. A handful of public Foundation declarations that Apple's
// iOS SDK ships are simply absent from it. Apple's retargeted SwiftUI/SwiftUICore
// interfaces reference those declarations in their signatures, so they must exist
// somewhere for the module to be recompiled.
//
// They cannot be added to `Foundation` (a prebuilt binary module) and cannot be provided
// by shadowing `Foundation`, so they live here. `scripts/port/retarget_interface.py`
// requalifies exactly these references (rule R10) — the table is at the top of that
// script and mirrored in docs/PORT-SDK.md. Nothing else in the interface text changes.
//
// Each declaration is copied from Apple's shipped
// `Foundation.framework/Modules/Foundation.swiftmodule/arm64-apple-ios-simulator.swiftinterface`
// or from the corresponding `Foundation.framework/Headers/*.h`, with the member set
// reduced to what the retargeted interfaces reference (noted per type). Bodies are
// `fatalError()` placeholders: the Android runtime decides what a `LocalizedStringResource`
// or an `NSItemProvider` means on this platform.
//
// SKIPPED ON PURPOSE: `URLRequest` is *not* declared here. It does exist on Android — in
// the real `FoundationNetworking` module — so R10 requalifies `Foundation.URLRequest` to
// `FoundationNetworking.URLRequest` instead of faking it.
public import Foundation

// MARK: - AttributedString.AttributeRunBoundaries  (Foundation.swiftinterface line 1154)

/// `public enum AttributeRunBoundaries : Hashable, Sendable` — a nested type of
/// `AttributedString` on Darwin; top-level here (see PORT-SDK.md, "qualification rewrites").
public enum AttributeRunBoundaries: Hashable, Sendable {
    case paragraph
    case character(Character)
}

// MARK: - Date.ComponentsFormatStyle (Foundation.swiftinterface line 23264)

/// `public struct ComponentsFormatStyle : FormatStyle, Codable, Hashable, Sendable`.
/// `FormatStyle` is not declared here: the Android Foundation's protocol requires
/// `FormatInput`/`FormatOutput`/`format(_:)`, none of which the interface uses.
public struct ComponentsFormatStyle: Hashable, Sendable {
    public init() { fatalError() }

    public typealias Field = ComponentsFormatStyleField

    public var allowedFields: Set<Field> { fatalError() }

    public func allowedFields(_ fields: Set<Field>) -> ComponentsFormatStyle { fatalError() }
}

// MARK: - Date.ComponentsFormatStyle.Field / Date.RelativeFormatStyle.Field

/// The `Field` option sets of the two date format styles. On Darwin they are nested under
/// the format style; the retargeted interfaces reference them with a nested-module
/// spelling, so they are also declared top-level here (see PORT-SDK.md).
public struct ComponentsFormatStyleField: Hashable, Sendable, OptionSet {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let year = ComponentsFormatStyleField(rawValue: 1 << 0)
    public static let month = ComponentsFormatStyleField(rawValue: 1 << 1)
    public static let week = ComponentsFormatStyleField(rawValue: 1 << 2)
    public static let day = ComponentsFormatStyleField(rawValue: 1 << 3)
    public static let weekday = ComponentsFormatStyleField(rawValue: 1 << 4)
    public static let hour = ComponentsFormatStyleField(rawValue: 1 << 5)
    public static let minute = ComponentsFormatStyleField(rawValue: 1 << 6)
    public static let second = ComponentsFormatStyleField(rawValue: 1 << 7)
}

public struct RelativeFormatStyleField: Hashable, Sendable, OptionSet {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let year = RelativeFormatStyleField(rawValue: 1 << 0)
    public static let month = RelativeFormatStyleField(rawValue: 1 << 1)
    public static let week = RelativeFormatStyleField(rawValue: 1 << 2)
    public static let day = RelativeFormatStyleField(rawValue: 1 << 3)
    public static let weekday = RelativeFormatStyleField(rawValue: 1 << 4)
    public static let hour = RelativeFormatStyleField(rawValue: 1 << 5)
    public static let minute = RelativeFormatStyleField(rawValue: 1 << 6)
    public static let second = RelativeFormatStyleField(rawValue: 1 << 7)
}

// MARK: - Date.RelativeFormatStyle (Foundation.swiftinterface line 14667)

/// `public struct RelativeFormatStyle : Codable, Hashable, Sendable`.
public struct RelativeFormatStyle: Hashable, Sendable {
    public init() { fatalError() }

    public typealias Field = RelativeFormatStyleField

    public var allowedFields: Set<Field> { fatalError() }

    public func allowedFields(_ fields: Set<Field>) -> RelativeFormatStyle { fatalError() }
}

// MARK: - NumberFormatStyleConfiguration.SignDisplayStrategy (line 16598)

/// `public struct SignDisplayStrategy : Codable, Hashable, CustomStringConvertible, Sendable`.
public struct SignDisplayStrategy: Hashable, Sendable, CustomStringConvertible {
    public static var automatic: SignDisplayStrategy { fatalError() }

    public static var never: SignDisplayStrategy { fatalError() }

    public static func always(includingZero: Bool = true) -> SignDisplayStrategy { fatalError() }

    public var description: String { fatalError() }
}

// MARK: - Locale.Language (Foundation.swiftinterface line 10792)

/// `public struct Language : Hashable, Codable, Sendable`.
public struct Language: Hashable, Codable, Sendable {
    public struct Components: Hashable, Codable, Sendable {
        public init() { fatalError() }
    }

    public init() { fatalError() }

    public init(components: Language.Components) { fatalError() }

    public init(languageCode: Locale.LanguageCode? = nil,
                script: Locale.Script? = nil,
                region: Locale.Region? = nil) { fatalError() }

    public static var systemLanguages: [Language] { fatalError() }
}

// MARK: - AttributeScopes.FoundationAttributes (Foundation.swiftinterface line 1717)

/// `public struct FoundationAttributes : AttributeScope`. Only ever stored as a value
/// inside SwiftUI's `SwiftUIAttributes`, so its attribute keys are not replicated.
public struct FoundationAttributes: AttributeScope {
    public init() { fatalError() }
}

// MARK: - LocalizedStringResource (Foundation.swiftinterface line 22136)

/// `public struct LocalizedStringResource : Equatable, Codable,
/// CustomLocalizedStringResourceConvertible, ExpressibleByStringInterpolation`.
/// `CustomLocalizedStringResourceConvertible` does not exist in the Android Foundation,
/// so that conformance is omitted (documented as a semantic gap).
public struct LocalizedStringResource: Equatable, Hashable, Sendable {
    /// The port renders text through `Text(verbatim:)`, so the resource only needs to carry its
    /// key; localisation itself is a semantic gap (no resource bundles on Android yet).
    public var key: String

    public init(_ key: String, table: String? = nil, locale: Locale = .current,
                bundle: Bundle? = nil, comment: StaticString? = nil) {
        self.key = key
    }

    public init(stringLiteral value: String) {
        self.key = value
    }

    public init(stringInterpolation: StringInterpolation) {
        self.key = stringInterpolation.key
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        public var key: String = ""

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            key += literal
        }

        public mutating func appendInterpolation(_ value: String) {
            key += value
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += String(describing: value)
        }
    }
}

extension LocalizedStringResource: ExpressibleByStringLiteral {}

// MARK: - The ObjC classes the Android Foundation does not build

// NSItemProvider.h — used for drop/paste payloads.
open class NSItemProvider: NSObject {
    public override init() { fatalError() }
}

// NSUserActivity.h — SwiftUI's `.userActivity(...)` API. SwiftUI itself declares the
// nested `TypedPayloadError` type (interface line 21256), so only the class is here.
open class NSUserActivity: NSObject {
    public override init() { fatalError() }

    public init(activityType: String) { fatalError() }

    public var activityType: String { fatalError() }
}

// NSFileCoordinator.h — document/file APIs.
open class NSFileCoordinator: NSObject {
    public override init() { fatalError() }

    public init(filePresenter: Any?) { fatalError() }
}

// NSFileWrapper.h — document APIs.
open class FileWrapper: NSObject {
    public override init() { fatalError() }

    public var isRegularFile: Bool { fatalError() }
}

// NSUndoManager.h — `EnvironmentValues.undoManager`.
open class UndoManager: NSObject {
    public override init() { fatalError() }

    public func undo() { fatalError() }

    public func redo() { fatalError() }
}

// NSKeyValueObserving.h — `NSKeyValueChangeKey`, an `NS_TYPED_EXTENSIBLE_ENUM` over
// NSString; imported by Swift as a `RawRepresentable` struct.
public struct NSKeyValueChangeKey: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - String.StandardComparator.localizedStandard  (Foundation.swiftinterface)
//
// `String.StandardComparator.localizedStandard` is Apple's localized string ordering.
// The Swift SDK for Android's Foundation ships `String.StandardComparator` but not the
// static member, so it is added here (R10). SwiftUI uses it as the default comparator of
// `Table`/`Section` sorting.
extension String.StandardComparator {
    public static var localizedStandard: String.StandardComparator { fatalError() }
}
