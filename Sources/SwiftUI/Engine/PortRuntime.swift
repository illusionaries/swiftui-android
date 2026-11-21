// PortRuntime.swift — the seam between Apple's declarations and the Android engine.
//
// `Sources/SwiftUI/Generated/` holds Apple's SwiftUI/SwiftUICore declarations, mechanically
// extracted from the shipped `.swiftinterface` files. Declarations that ship an `@inlinable`
// body keep Apple's own code; every other body is replaced by a call into this file, which is
// where the port actually gets implemented.
//
// Nothing in this file is invented API: it is the private scaffolding the port adds beneath
// Apple's public surface.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Reported when execution reaches a SwiftUI entry point the port has not implemented yet.
@inline(never)
public func _suiUnimplemented(_ symbol: String) -> Never {
    PortDiagnostics.reportUnimplemented(symbol)
    fatalError("SwiftUI port: unimplemented entry point \(symbol). Add it to Sources/SwiftUI/Engine/.")
}

/// Diagnostics sink, also used by the harness to assert coverage of a rendered screen.
public enum PortDiagnostics {
    nonisolated(unsafe) public private(set) static var unimplementedHits: [String] = []
    nonisolated(unsafe) public static var verbose = false

    public static func reportUnimplemented(_ symbol: String) {
        unimplementedHits.append(symbol)
    }
}

/// Placeholder `Sequence.Iterator` for generated conformances whose real iterator type lives in
/// a constrained extension Apple splits across its two interfaces.
///
/// A `.swiftinterface` can leave an associated type to be inferred from a witness in a *different*
/// module's interface half; merged into one module that inference has no witness to lean on. The
/// generator substitutes this concrete iterator so the conformance still exists and is callable —
/// it just traps, because iteration over these SPI collections is not part of the port yet.
public struct _PortIterator: IteratorProtocol {
    public typealias Element = Never

    public init() {}

    public mutating func next() -> Never? {
        _suiUnimplemented("_PortIterator.next")
    }
}
