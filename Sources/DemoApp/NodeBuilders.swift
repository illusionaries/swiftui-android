// NodeBuilders.swift — modifier-shaped conveniences over the port's layout tree.
//
// These mirror SwiftUI's modifier names one-for-one so that application code reads the same
// as it will once it is written against Apple's declarations:
//     LayoutNode.text(…).padding(16).background(…).cornerRadius(18).shadow(…)
import Foundation
import SwiftUI

extension LayoutNode {
    func padding(_ insets: EdgeInsetsLike) -> LayoutNode { .padding(insets, self) }
    func padding(_ all: CGFloat) -> LayoutNode { .padding(all, self) }
    func padding(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> LayoutNode {
        .padding(EdgeInsetsLike(top: vertical, bottom: vertical, leading: horizontal, trailing: horizontal), self)
    }

    func frame(_ spec: FrameSpec) -> LayoutNode { .frame(spec, self) }
    func width(_ value: CGFloat) -> LayoutNode { .frame(FrameSpec.width(value), self) }
    func height(_ value: CGFloat) -> LayoutNode { .frame(FrameSpec.height(value), self) }
    func frame(maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) -> LayoutNode {
        .frame(FrameSpec(maxWidth: maxWidth, maxHeight: maxHeight), self)
    }

    func background(_ node: LayoutNode) -> LayoutNode { .background(node, self) }
    func overlay(_ node: LayoutNode) -> LayoutNode { .overlay(node, self) }
    func cornerRadius(_ radius: CGFloat) -> LayoutNode { LayoutNode(.clip(cornerRadius: radius), self) }
    func shadow(dx: CGFloat = 0, dy: CGFloat = 6, blur: CGFloat = 16,
                color: RGBAColor, cornerRadius: CGFloat = 0) -> LayoutNode {
        LayoutNode(.shadow(dx: dx, dy: dy, blur: blur, color: color, cornerRadius: cornerRadius), self)
    }
    func opacity(_ value: CGFloat) -> LayoutNode { LayoutNode(.opacity(value), self) }

    /// Rounded background fill, the most common decoration in this app.
    func surfaceFill(_ fill: PortFillStyle, radius: CGFloat) -> LayoutNode {
        background(LayoutNode(.shape(.roundedRectangle(cornerRadius: radius), fill: fill, stroke: nil)))
    }
}
