// CoreTransferable — platform shim for the Android port.
//
// WHY THIS IS NOT RETARGETED
// --------------------------
// Apple ships CoreTransferable.framework/Modules/CoreTransferable.swiftmodule/
// arm64-apple-ios-simulator.swiftinterface (258 lines), but it cannot be recompiled
// off-Darwin:
//
//  1. Its conformances (`AttributedString: Transferable`, `Data: Transferable`,
//     `URL: Transferable`) are witnesses whose associated type is spelled
//     `@_opaqueReturnTypeOf("$s...transferRepresentationQrvpZ", 0) __`.  That attribute
//     resolves the opaque type against a *prebuilt binary* module; when the module is
//     rebuilt from text there is nothing to resolve against, and the conformances fail.
//  2. Its `CodableRepresentation` requires `Foundation.JSONEncoder : Combine.TopLevelEncoder`,
//     an Apple-only conformance, and `CFSwifted`/`NSItemProvider` plumbing.
//  3. Recompiling it with `-enable-library-evolution` against the Swift SDK for
//     Android's `Foundation` (which is *not* ABI-stable) is rejected outright.
//
// What the retargeted SwiftUI interface actually uses from this module is exactly two
// protocols — `Transferable` and `TransferRepresentation` — plus the conformance
// `extension SwiftUICore.Color : Transferable` and the drag-and-drop entry points
// constrained to `T : Transferable`. Those declarations are copied below from Apple's
// interface (lines 88-92 and 249-252 of the `.swiftinterface`).
//
// Bodies are `fatalError()` on purpose: this shim only has to make Apple's interface
// compile. Real drag-and-drop / document transfer is Android-runtime work.
public import Swift

// MARK: - TransferRepresentation  (interface line 88)

public protocol TransferRepresentation<Item>: Sendable {
    associatedtype Item: Transferable
    associatedtype Body: TransferRepresentation

    @TransferRepresentationBuilder<Self.Item> var body: Self.Body { get }
}

// MARK: - TransferRepresentationBuilder  (interface line 94)

@resultBuilder
public struct TransferRepresentationBuilder<Item> where Item: Transferable {
    public static func buildBlock<Content>(_ content: Content) -> Content
        where Item == Content.Item, Content: TransferRepresentation { fatalError() }
}

// MARK: - Transferable  (interface line 249)

public protocol Transferable: Sendable {
    associatedtype Representation: TransferRepresentation

    @TransferRepresentationBuilder<Self> static var transferRepresentation: Self.Representation { get }
}

// MARK: - TransferRepresentationVisibility  (interface line ~231)

public struct TransferRepresentationVisibility: Sendable, Equatable {
    public static let all = TransferRepresentationVisibility()

    public static let ownProcess = TransferRepresentationVisibility()

    private init() { fatalError() }

    public static func == (a: TransferRepresentationVisibility, b: TransferRepresentationVisibility) -> Bool {
        fatalError()
    }
}
