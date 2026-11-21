// AppEntry.swift — the single C entry point the Android runtime resolves.
//
// Which scene runs depends on how the package was built:
//   • default build            → AtlasScene (the engine-level app, docs/DEMO.md)
//   • SWIFTUI_PORT_GENERATED=1 → SwiftUIHostScene (a real SwiftUI view hosted through Apple's
//                                declarations and the renderer adapters, docs/RENDERER.md)
import Foundation
import SwiftUI

@_cdecl("swiftui_app_entry")
public func swiftuiAppEntry() -> UnsafeMutableRawPointer? {
    #if PORT_RENDERER
    return Unmanaged.passRetained(SwiftUIHostScene() as AnyObject).toOpaque()
    #else
    return Unmanaged.passRetained(AtlasScene() as AnyObject).toOpaque()
    #endif
}
