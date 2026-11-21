// DemoScene.swift — the demo app's scene, built with the port's layout engine.
//
// Everything below is expressed as a LayoutNode tree (stacks, spacers, padding, frames,
// fills, shapes, backgrounds, overlays, shadows) and painted through the same DisplayList
// pipeline that Apple's declared views will feed once the `_makeView` adapters land.
//
// This is the on-device test of Sources/SwiftUI/Engine: measure → place → paint, in dp,
// rendered by Android's Canvas via the C bridge.
import Foundation
import SwiftUI

public final class DemoScene: PortScene {
    private var taps = 0
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
        if tree == nil { rebuild() }
    }

    private var ink: RGBAColor { isDark ? .white : RGBAColor(hex: 0x111114) }
    private var subtleInk: RGBAColor { isDark ? RGBAColor(hex: 0x9A9AA2) : RGBAColor(hex: 0x6C6C74) }
    private var surface: RGBAColor { isDark ? RGBAColor(hex: 0x1C1C22) : .white }

    private func rebuild() {
        let title = LayoutNode.vstack(spacing: 2, horizontalAlignment: 0, [
            LayoutNode.text("SwiftUI", style: .init(size: 34, weight: .bold, color: ink)),
            LayoutNode.text("porting Apple's framework to Android",
                            style: .init(size: 15, color: subtleInk)),
        ])

        let pill = LayoutNode.padding(EdgeInsetsLike(top: 8, bottom: 8, leading: 14, trailing: 14),
                                      LayoutNode.text("arm64 · API 35",
                                                      style: .init(size: 13, weight: .semibold, color: .white)))
            .withBackground(
                LayoutNode(.shape(.capsule, fill: .color(RGBAColor(white: 1, alpha: 0.22)), stroke: nil))
            )

        let heroContent = LayoutNode.vstack(spacing: 6, horizontalAlignment: 0, [
            LayoutNode.text("Native Swift", style: .init(size: 28, weight: .bold, color: .white)),
            LayoutNode.text("layout engine → display list → Skia",
                            style: .init(size: 14, weight: .medium, color: RGBAColor(white: 1, alpha: 0.85))),
            LayoutNode.spacer(minLength: 10),
            LayoutNode.hstack(spacing: 0, [pill, LayoutNode.spacer()]),
        ])

        let hero = LayoutNode.padding(EdgeInsetsLike(top: 24, bottom: 24, leading: 24, trailing: 24), heroContent)
            .withBackground(
                LayoutNode.gradient([RGBAColor(hex: 0x5B7CFA), RGBAColor(hex: 0x9B5BFA), RGBAColor(hex: 0xF25BC0)],
                                    start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
            )
            .withFrame(FrameSpec.height(200))
            .withCornerRadius(22)
            .withShadow(dx: 0, dy: 8, blur: 18, color: RGBAColor(hex: 0x000000, alpha: isDark ? 0.55 : 0.16))

        let badge = LayoutNode(.shape(.circle, fill: .color(RGBAColor(hex: 0x0A84FF, alpha: 0.16)), stroke: nil))
            .withFrame(FrameSpec.width(36).merging(FrameSpec.height(36)))
            .withOverlay(
                LayoutNode.text("+", style: .init(size: 20, weight: .semibold, color: RGBAColor(hex: 0x0A84FF)))
            )

        let tapsRow = LayoutNode.hstack(spacing: 12, [
            LayoutNode.vstack(spacing: 2, horizontalAlignment: 0, [
                LayoutNode.text("Taps", style: .init(size: 17, weight: .semibold, color: ink)),
                LayoutNode.text("\(taps)", style: .init(size: 15, color: subtleInk)),
            ]),
            LayoutNode.spacer(),
            badge,
        ])
        .withPadding(EdgeInsetsLike(top: 16, bottom: 16, leading: 20, trailing: 20))
        .withBackground(LayoutNode(.shape(.roundedRectangle(cornerRadius: 18), fill: .color(surface), stroke: nil)))

        let ladder = LayoutNode.vstack(spacing: 10, horizontalAlignment: 0, [
            LayoutNode.text("Headline sample", style: .init(size: 22, weight: .semibold, color: ink)),
            LayoutNode.text("Body text at 17pt with normal weight", style: .init(size: 17, color: ink)),
            LayoutNode.text("Footnote 13pt secondary", style: .init(size: 13, color: subtleInk)),
        ])

        let content = LayoutNode.vstack(spacing: 20, horizontalAlignment: 0, [
            title,
            hero,
            tapsRow,
            ladder,
            LayoutNode.spacer(),
        ])

        tree = LayoutNode.padding(
            EdgeInsetsLike(top: max(20, safeArea.top + 12), bottom: 24, leading: 20, trailing: 20),
            content
        )
    }

    public func handleTap(at point: CGPoint) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return false }
        taps += 1
        rebuild()
        return true
    }

    public func draw(into list: inout DisplayList, context: SceneContext) {
        let background = isDark ? RGBAColor(hex: 0x0B0B0F) : RGBAColor(hex: 0xF5F5F7)
        list.append(.fillRect(CGRect(x: 0, y: 0, width: width, height: height), background))

        guard let tree else { return }
        let proposal = ProposedSize(width: width, height: height)
        let size = tree.measure(proposal)
        tree.place(in: CGRect(x: 0, y: 0, width: width, height: max(size.height, height)))
        TextMeasurement.current = context.measurer
        tree.paint(into: &list)
    }
}

// MARK: - Small builders that mirror SwiftUI modifier names

extension LayoutNode {
    func withPadding(_ insets: EdgeInsetsLike) -> LayoutNode { .padding(insets, self) }
    func withFrame(_ spec: FrameSpec) -> LayoutNode { .frame(spec, self) }
    func withBackground(_ background: LayoutNode) -> LayoutNode { .background(background, self) }
    func withOverlay(_ overlay: LayoutNode) -> LayoutNode { .overlay(overlay, self) }
    func withCornerRadius(_ radius: CGFloat) -> LayoutNode { LayoutNode(.clip(cornerRadius: radius), self) }
    func withShadow(dx: CGFloat, dy: CGFloat, blur: CGFloat, color: RGBAColor) -> LayoutNode {
        LayoutNode(.shadow(dx: dx, dy: dy, blur: blur, color: color), self)
    }
}

extension FrameSpec {
    func merging(_ other: FrameSpec) -> FrameSpec {
        FrameSpec(minWidth: minWidth ?? other.minWidth,
                  idealWidth: idealWidth ?? other.idealWidth,
                  maxWidth: maxWidth ?? other.maxWidth,
                  minHeight: minHeight ?? other.minHeight,
                  idealHeight: idealHeight ?? other.idealHeight,
                  maxHeight: maxHeight ?? other.maxHeight,
                  horizontalAlignment: other.horizontalAlignment,
                  verticalAlignment: other.verticalAlignment)
    }
}

/// The runtime loads this symbol by name (dlsym) to discover the app's scene.
@_cdecl("swiftui_app_entry")
public func swiftuiAppEntry() -> UnsafeMutableRawPointer? {
    Unmanaged.passRetained(DemoScene() as AnyObject).toOpaque()
}
