// PortLinkOpener.swift — the seam between a ported `Link` and the platform's URL handler.
//
// Following a link is an operating-system job: iOS hands the URL to UIKit/UIApplication, Android
// hands it to an `Intent.ACTION_VIEW`. The framework module cannot call either, so the direction is
// declared here and the platform runtime installs the implementation, exactly like `PortTextInput`:
//
//   PortLinkOpener.open(url)  ->  host?(url)  ->  the window opens the URL
//
// With no host installed (the engine-only host test build) opening a link is a no-op, which keeps
// the module testable off-device.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

public enum PortLinkOpener {
    /// Installed once by the platform runtime that owns the window. Called on the UI thread.
    nonisolated(unsafe) public static var host: ((URL) -> Void)?

    /// The last URL a control asked to open, for the demos' on-screen diagnostics.
    nonisolated(unsafe) public private(set) static var lastRequested: URL?

    /// Ask the platform to open `url`. Harmless when no platform handler is installed.
    public static func open(_ url: URL) {
        lastRequested = url
        host?(url)
    }
}
