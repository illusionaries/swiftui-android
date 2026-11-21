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
