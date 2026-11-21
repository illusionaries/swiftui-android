// PortStyleRender.swift — draws colours, shapes and style modifiers.
//
// The engine knows how to paint fills, shapes, clips and shadows; these conformances are what
// teach the ported path to reach them from Apple's view and modifier types.
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#else
import Foundation
#endif
import FoundationShims

// MARK: - Colors as views

extension Color: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let rgba = PortStyleRegistry.rgba(of: self) ?? context.environment.foreground
        return [LayoutNode.color(rgba)]
    }
}

// MARK: - Shapes

extension _ShapeView: _PortRenderable where Style: ShapeStyle {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let fill: PortFillStyle
        if let style = self.style as? Color {
            fill = .color(PortStyleRegistry.rgba(of: style) ?? context.environment.foreground)
        } else if let gradient = self.style as? LinearGradient {
            let stops = PortStyleRegistry.stops(of: gradient.gradient)
            fill = .linearGradient(stops.isEmpty ? [context.environment.foreground, context.environment.foreground] : stops,
                                   start: CGPoint(x: gradient.startPoint.x, y: gradient.startPoint.y),
                                   end: CGPoint(x: gradient.endPoint.x, y: gradient.endPoint.y))
        } else {
            fill = .color(context.environment.foreground)
        }
        let kind = ShapeKind.kind(for: shape)
        return [LayoutNode(.shape(kind, fill: fill, stroke: nil))]
    }
}

// A bare shape (e.g. `Rectangle()` without `.fill`) draws in the environment's foreground colour.
extension Rectangle: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [LayoutNode(.shape(.rectangle, fill: .color(context.environment.foreground), stroke: nil))]
    }
}

extension RoundedRectangle: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [LayoutNode(.shape(.roundedRectangle(cornerRadius: cornerSize.width),
                           fill: .color(context.environment.foreground), stroke: nil))]
    }
}

extension Circle: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [LayoutNode(.shape(.circle, fill: .color(context.environment.foreground), stroke: nil))]
    }
}

extension Capsule: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [LayoutNode(.shape(.capsule, fill: .color(context.environment.foreground), stroke: nil))]
    }
}

// MARK: - Gradients
//
// `Gradient.stops` and `LinearGradient`'s fields are real storage in the interface, so gradients
// need no side table: only their initializers are supplied — as bodies (port-impl/bodies.txt)
// rather than as replacements, because Swift synthesises memberwise initializers for them.

extension Gradient {
    /// Apple's interface only declares `init(stops:)`; its `init(colors:)` is a convenience the
    /// generated inlinable bodies still call, so the port supplies it.
    public init(colors: [Color]) {
        self.init(stops: colors.enumerated().map { index, color in
            Gradient.Stop(color: color,
                          location: colors.count > 1 ? CGFloat(index) / CGFloat(colors.count - 1) : 0)
        })
    }
}

extension PortStyleRegistry {
    /// Maps a gradient's stops onto engine colours, skipping any colour the port did not create.
    static func stops(of gradient: Gradient) -> [RGBAColor] {
        gradient.stops.compactMap { rgba(of: $0.color) }
    }
}
