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
        VStack(spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 10) {
                Text("Gradients, shapes, shadows")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("RoundedRectangle, LinearGradient, shadow")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerSize: CGSize(width: 20, height: 20))
                    .fill(LinearGradient(colors: [.indigo, .pink],
                                         startPoint: UnitPoint(x: 0, y: 0),
                                         endPoint: UnitPoint(x: 1, y: 1)))
            )
            .shadow(color: .black, radius: 12, x: 0, y: 6)

            HStack(spacing: 12) {
                stat(value: "128", label: "screens", tint: .green)
                stat(value: "4.9", label: "rating", tint: .orange)
            }

            VStack(spacing: 12) {
                Text("Taps: \(PortDemoCounter.count)")
                    .font(.headline)
                HStack(spacing: 12) {
                    Button("Tap me") { PortDemoCounter.count += 1 }
                    Button("Reset") { PortDemoCounter.count = 0 }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerSize: CGSize(width: 16, height: 16))
                    .fill(Color.blue.opacity(0.12))
            )
        }
        .padding(20)
    }

    var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerSize: CGSize(width: 14, height: 14))
                .fill(Color.blue)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ported SwiftUI")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Apple's declarations, Android canvas")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    func stat(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerSize: CGSize(width: 16, height: 16))
                .fill(tint)
        )
    }
}

/// Stand-in for `@State` while dynamic properties are still stubbed: the host rebuilds the view
/// tree on every frame, so a plain global reads back the value the buttons changed.
enum PortDemoCounter {
    nonisolated(unsafe) static var count = 0
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
        tree = root
        root.paint(into: &list)
    }

    public func handleTap(at point: CGPoint) -> Bool {
        guard let hit = tree?.hitTest(point) else { return false }
        hit.action?()
        return hit.action != nil
    }

    public func handleDrag(_ gesture: PortDragGesture) -> Bool { false }
}

