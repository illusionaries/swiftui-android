// SwiftUIHostScene.swift — hosts a real SwiftUI view tree on the port's engine.
//
// This is the bridge between Apple's declared `View` protocol and the engine: it materialises the
// root view through `PortGraphContext`, then measures, places and paints the resulting tree like
// any other scene.
import Foundation
import SwiftUI

/// A first screen written in genuine SwiftUI syntax and rendered through Apple's declarations.
struct PortDemoView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("SwiftUI")
            Text("rendered from Apple's declarations")
            Text("Swift -> JNI -> Skia canvas")
        }
        .padding(24)
    }
}

public final class SwiftUIHostScene: PortScene {
    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var isDark = false
    private var safeArea = EdgeInsetsLike.zero
    private var tree: LayoutNode?

    public init() {}

    public func update(_ context: SceneContext) {
        width = context.size.width
        height = context.size.height
        isDark = context.isDark
        safeArea = context.safeArea
    }

    public func draw(into list: inout DisplayList, context: SceneContext) {
        list.append(.fillRect(CGRect(x: 0, y: 0, width: width, height: height),
                              isDark ? RGBAColor(hex: 0x0B0B0F) : RGBAColor(hex: 0xF5F5F7)))

        let graph = PortGraphContext.shared
        graph.beginFrame(environment: PortEnvironment(isDark: isDark,
                                                      accentColor: RGBAColor(hex: 0x0A84FF),
                                                      displayScale: context.displayScale))
        let root = graph.makeNode(PortDemoView(), proposal: ProposedSize(width: width, height: height))
        graph.endFrame()

        let size = root.measure(ProposedSize(width: width, height: height))
        root.place(in: CGRect(x: 0, y: max(safeArea.top, 0), width: width, height: max(size.height, height)))
        root.paint(into: &list)
    }

    public func handleTap(at point: CGPoint) -> Bool {
        guard let hit = tree?.hitTest(point) else { return false }
        hit.action?()
        return hit.action != nil
    }

    public func handleDrag(_ gesture: PortDragGesture) -> Bool { false }
}

@_cdecl("swiftui_port_entry")
public func swiftuiPortAppEntry() -> UnsafeMutableRawPointer? {
    Unmanaged.passRetained(SwiftUIHostScene() as AnyObject).toOpaque()
}
