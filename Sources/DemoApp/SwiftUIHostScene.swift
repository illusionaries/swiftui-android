// SwiftUIHostScene.swift — hosts a real SwiftUI view tree on the port's engine.
//
// This is the bridge between Apple's declared `View` protocol and the engine: it materialises the
// root view through `PortGraphContext`, then measures, places and paints the resulting tree like
// any other scene.
import Foundation
import SwiftUI

/// A first screen written in genuine SwiftUI syntax and rendered through Apple's declarations.
struct PortDemoView: View {
    @State private var taps = 0

    private let rows = Array(1...14)

    var body: some View {
        VStack(spacing: 14) {
            header

            ScrollView {
                VStack(spacing: 12) {
                    gradientCard
                    HStack(spacing: 12) {
                        stat(value: "128", label: "screens", tint: .green)
                        stat(value: "4.9", label: "rating", tint: .orange)
                    }
                    tapCard
                    ForEach(rows, id: \.self) { index in
                        row(index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 560)
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

    var gradientCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gradients, shapes, shadows")
                .font(.headline)
                .foregroundColor(.white)
            Text("RoundedRectangle filled with a LinearGradient, clipped and shadowed")
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
    }

    var tapCard: some View {
        VStack(spacing: 12) {
            Text("Taps: \(taps)")
                .font(.headline)
            HStack(spacing: 12) {
                Button("Tap me") { taps += 1 }
                Button("Reset") { taps = 0 }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerSize: CGSize(width: 16, height: 16))
                .fill(Color.blue.opacity(0.12))
        )
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

    func row(_ index: Int) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(index.isMultiple(of: 2) ? Color.indigo : Color.teal)
                .frame(width: 28, height: 28)
            Text("Row \(index)")
                .font(.body)
            Spacer()
            Text("ForEach")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerSize: CGSize(width: 12, height: 12))
                .fill(Color.white)
        )
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
        let root = graph.makeNode(AtlasRootView(), proposal: ProposedSize(width: width, height: height))
        graph.endFrame()

        let size = root.measure(ProposedSize(width: width, height: height))
        let topInset = max(safeArea.top, 0)
        let bottomInset = max(safeArea.bottom, 0)
        root.place(in: CGRect(x: 0, y: topInset, width: width,
                              height: max(size.height, height - topInset - bottomInset)))
        tree = root
        root.paint(into: &list)

        if PortDiagnostics.verbose {
            // Compact layout report: every vertical stack with its children's heights, so a
            // collapsing container is obvious at a glance.
            list.append(.fillRect(CGRect(x: 0, y: 0, width: width, height: 400),
                                  RGBAColor(hex: 0xFFFFFF)))
            var y: CGFloat = 2
            func report(_ node: LayoutNode, _ path: String, _ depth: Int) {
                guard depth < 14, y < 395 else { return }
                if case let .stack(axis, spacing, _, _) = node.kind, axis == .vertical {
                    let heights = node.children.map { Int($0.frame.height) }
                    list.append(.text("\(path) v sp\(Int(spacing)) n\(node.children.count) h\(heights)",
                                      origin: CGPoint(x: 4, y: y),
                                      style: TextStyleDescriptor(size: 9, weight: .regular,
                                                                 color: RGBAColor(hex: 0xCC0000))))
                    y += 11
                }
                for (index, child) in node.children.enumerated() {
                    report(child, path + ".\(index)", depth + 1)
                }
            }
            report(root, "r", 0)
        }
    }

    public func handleTap(at point: CGPoint) -> Bool {
        guard let hit = tree?.hitTest(point) else { return false }
        hit.action?()
        return hit.action != nil
    }

    public func handleDrag(_ gesture: PortDragGesture) -> Bool {
        PortScrollStore.apply(drag: gesture, at: gesture.location)
    }
}

