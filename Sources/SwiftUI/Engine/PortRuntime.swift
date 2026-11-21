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
import Foundation
#else
import Foundation
#endif

/// Reported when execution reaches a SwiftUI entry point the port has not implemented yet.
@inline(never)
public func _suiUnimplemented(_ symbol: String) -> Never {
    PortDiagnostics.reportUnimplemented(symbol)
    // Visible in `adb logcat` (stderr) so a trap names the entry point the port still owes.
    FileHandle.standardError.write(Data("SwiftUI port: unimplemented entry point \(symbol)\n".utf8))
    fatalError("SwiftUI port: unimplemented entry point \(symbol). Add it to Sources/SwiftUI/Adapters/.")
}

/// Diagnostics sink, also used by the harness to assert coverage of a rendered screen.
public enum PortDiagnostics {
    nonisolated(unsafe) public internal(set) static var unimplementedHits: [String] = []
    nonisolated(unsafe) public static var verbose = false
    /// The last tap the host scene received and the frame the last text field was laid out in
    /// (dp, scene space). The ported APK is not debuggable, so a demo printing these on screen is
    /// the cheapest way to answer "did the touch arrive, and where is the control?".
    nonisolated(unsafe) public static var lastTap: CGPoint?
    nonisolated(unsafe) public static var lastTapPath: [String] = []
    /// The scroll model the last frame laid out, as text (content/viewport/max/offset).
    nonisolated(unsafe) public static var scrollModel: String?

    public static func reportUnimplemented(_ symbol: String) {
        unimplementedHits.append(symbol)
    }

    /// Verbose progress on stderr, which `adb logcat` captures — used while bringing up the
    /// renderer to see which adapter a view actually dispatches to.
    public static func log(_ message: String) {
        guard verbose else { return }
        let line = "SwiftUI port: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        // Android does not forward the app's stderr to logcat, so also append to a file that a
        // debugger can pull with `adb shell run-as … cat cache/port.log`.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("port.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
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
