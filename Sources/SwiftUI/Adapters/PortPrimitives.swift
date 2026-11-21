// PortPrimitives.swift — how the port's engine renders SwiftUI's built-in views.
//
// Each conformance reads the value Apple's interface exposes (their internal storage is public in
// the interface) and produces engine nodes. Nothing here re-declares API: the declarations stay in
// Generated/, and this file supplies only the behaviour Apple's binary would have provided.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import FoundationShims

// MARK: - Text

extension Text: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [PortAdapters.node(for: self, environment: context.environment)]
    }
}

// MARK: - Leaf views

extension EmptyView: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [LayoutNode(.empty)]
    }
}

extension Spacer: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [LayoutNode.spacer(minLength: minLength ?? 0)]
    }
}

// MARK: - Text initializers
//
// `Text("…")` funnels through these; Apple's bodies are in its binary. Both store an explicit
// verbatim string, which is what Apple's own `init(verbatim:)` does inlinably.

extension Text {
    // `@_disfavoredOverload` is Apple's own ranking on this initializer: string literals prefer the
    // LocalizedStringKey/LocalizedStringResource overloads, and generated @inlinable bodies rely on
    // that ordering.
    @_disfavoredOverload
    public init<S>(_ content: S) where S: StringProtocol {
        self.init(verbatim: String(content))
    }

    /// Generated `@inlinable` bodies call this overload, so the port supplies the body.
    public init(_ resource: FoundationShims.LocalizedStringResource) {
        self.init(verbatim: resource.key)
    }

    /// The localised-key overload (`Text("Hello")` funnels through it). Android has no resource
    /// bundles yet, so the key itself is shown — the same text Apple displays for a literal.
    public init(_ key: LocalizedStringKey, tableName: String? = nil, bundle: Bundle? = nil,
                comment: StaticString? = nil) {
        self.init(verbatim: key.key)
    }
}

// MARK: - Stacks

extension VStack: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let children = context.makeNodes(_tree.content, proposal: proposal)
        let spacing = _tree.root.spacing ?? PortAdapters.defaultStackSpacing
        return [LayoutNode(.stack(axis: .vertical, spacing: spacing,
                                  horizontalAlignment: PortAdapters.hMultiplier(_tree.root.alignment),
                                  verticalAlignment: 0.5), children: children)]
    }
}

extension HStack: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let children = context.makeNodes(_tree.content, proposal: proposal)
        let spacing = _tree.root.spacing ?? PortAdapters.defaultStackSpacing
        return [LayoutNode(.stack(axis: .horizontal, spacing: spacing,
                                  horizontalAlignment: 0.5,
                                  verticalAlignment: PortAdapters.vMultiplier(_tree.root.alignment)),
                           children: children)]
    }
}

extension ZStack: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let children = context.makeNodes(_tree.content, proposal: proposal)
        return [LayoutNode(.zstack(horizontalAlignment: PortAdapters.hMultiplier(_tree.root.alignment.horizontal),
                                   verticalAlignment: PortAdapters.vMultiplier(_tree.root.alignment.vertical)),
                           children: children)]
    }
}

// MARK: - Tuples, optionals, conditionals

extension TupleView: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        var nodes: [LayoutNode] = []
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            guard let anyView = child.value as? any View else { continue }
            nodes.append(contentsOf: PortAdapters.makeNodes(anyView, proposal: proposal))
        }
        return nodes
    }
}

extension Optional: _PortRenderable where Wrapped: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        switch self {
        case let .some(wrapped): return context.makeNodes(wrapped, proposal: proposal)
        case .none: return []
        }
    }
}

// MARK: - Layout modifiers

extension ModifiedContent: _PortRenderable where Content: View, Modifier: ViewModifier {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let modifier = self.modifier

        if let padding = modifier as? _PaddingLayout {
            let insets = PortAdapters.edgeInsets(padding)
            let inner = ProposedSize(width: proposal.width.map { max(0, $0 - insets.leading - insets.trailing) },
                                     height: proposal.height.map { max(0, $0 - insets.top - insets.bottom) })
            let child = context.makeNode(content, proposal: inner)
            return [LayoutNode.padding(insets, child)]
        }

        if let frame = modifier as? _FlexFrameLayout {
            let spec = FrameSpec(minWidth: frame.minWidth, idealWidth: frame.idealWidth, maxWidth: frame.maxWidth,
                                 minHeight: frame.minHeight, idealHeight: frame.idealHeight, maxHeight: frame.maxHeight,
                                 horizontalAlignment: PortAdapters.hMultiplier(frame.alignment.horizontal),
                                 verticalAlignment: PortAdapters.vMultiplier(frame.alignment.vertical))
            let child = context.makeNode(content, proposal: proposal)
            return [LayoutNode.frame(spec, child)]
        }

        if let frame = modifier as? _FrameLayout {
            let spec = FrameSpec(minWidth: frame.width, idealWidth: frame.width, maxWidth: frame.width,
                                 minHeight: frame.height, idealHeight: frame.height, maxHeight: frame.height,
                                 horizontalAlignment: PortAdapters.hMultiplier(frame.alignment.horizontal),
                                 verticalAlignment: PortAdapters.vMultiplier(frame.alignment.vertical))
            let child = context.makeNode(content, proposal: proposal)
            return [LayoutNode.frame(spec, child)]
        }

        // Style-carrying modifiers adjust the environment for their subtree.
        if let font = modifier as? _EnvironmentKeyWritingModifier<Font?> {
            return context.withEnvironment { environment in
                environment.font = font.value.flatMap { PortStyleRegistry.spec(of: $0) }
            } body: {
                context.makeNodes(content, proposal: proposal)
            }
        }

        if let foreground = modifier as? _EnvironmentKeyWritingModifier<Color?> {
            return context.withEnvironment { environment in
                if let color = foreground.value, let rgba = PortStyleRegistry.rgba(of: color) {
                    environment.foreground = rgba
                }
            } body: {
                context.makeNodes(content, proposal: proposal)
            }
        }

        if let limit = modifier as? _EnvironmentKeyWritingModifier<Int?> {
            return context.withEnvironment { environment in
                environment.lineLimit = limit.value
            } body: {
                context.makeNodes(content, proposal: proposal)
            }
        }

        if let weight = modifier as? _EnvironmentKeyWritingModifier<Font.Weight?> {
            return context.withEnvironment { environment in
                if let weight = weight.value { environment.fontWeight = PortAdapters.textWeight(weight) }
            } body: {
                context.makeNodes(content, proposal: proposal)
            }
        }

        // `_OverlayModifier` / `_BackgroundModifier` are generic in the decorating view, so the
        // decoratee is read through reflection (the port cannot name `Background`).
        if let background = PortAdapters.child(of: modifier, named: "background", as: (any View).self) {
            let backdrop = context.makeNode(background, proposal: proposal)
            let front = context.makeNode(content, proposal: proposal)
            return [LayoutNode.background(backdrop, front)]
        }

        // `.background(_ style: some ShapeStyle)` and `.overlay(_ style:)` use a *different*
        // modifier type from the view-taking overloads: `_BackgroundStyleModifier` /
        // `_OverlayStyleModifier` store the style under `style`. Colour/gradient styles are also
        // Views, so they render through the same path.
        if let style = PortAdapters.child(of: modifier, named: "style", as: (any View).self) {
            let isOverlay = String(describing: Modifier.self).contains("Overlay")
            let other = context.makeNode(style, proposal: proposal)
            let base = context.makeNode(content, proposal: proposal)
            return [isOverlay ? LayoutNode.overlay(other, base) : LayoutNode.background(other, base)]
        }

        if let overlay = PortAdapters.child(of: modifier, named: "overlay", as: (any View).self) {
            let layer = context.makeNode(overlay, proposal: proposal)
            let base = context.makeNode(content, proposal: proposal)
            return [LayoutNode.overlay(layer, base)]
        }

        // `.clipShape(...)` is generic in the shape, so the shape is read by reflection and
        // mapped onto the engine's primitives.
        if let shape = PortAdapters.child(of: modifier, named: "shape", as: (any Shape).self) {
            let child = context.makeNode(content, proposal: proposal)
            let measured = child.measure(proposal)
            let radius: CGFloat
            switch shape {
            case let rounded as RoundedRectangle: radius = rounded.cornerSize.width
            case is Circle: radius = min(measured.width, measured.height) / 2
            case is Capsule: radius = min(measured.width, measured.height) / 2
            default: radius = 0
            }
            return [LayoutNode(.clip(cornerRadius: radius), children: [child])]
        }

        if let shadow = modifier as? _ShadowEffect {
            let rgba = PortStyleRegistry.rgba(of: shadow.color) ?? context.environment.foreground
            let child = context.makeNode(content, proposal: proposal)
            return [LayoutNode(.shadow(dx: shadow.offset.width, dy: shadow.offset.height,
                                       blur: shadow.radius, color: rgba),
                               children: [child])]
        }

        if let opacity = modifier as? _OpacityEffect {
            let child = context.makeNode(content, proposal: proposal)
            return [LayoutNode(.opacity(opacity.opacity), children: [child])]
        }

        // Unknown modifier for now: draw the content unchanged and record the symbol so the gap is
        // visible in PortDiagnostics rather than silently disappearing.
        context.noteUnimplemented("modifier \(String(reflecting: Modifier.self))")
        return context.makeNodes(content, proposal: proposal)
    }
}

// MARK: - Helpers bridging Apple's values to engine values

enum PortAdapters {
    static let defaultStackSpacing: CGFloat = 8

    /// Alignment identity comes from the port's registry (see PortAlignment.swift).
    static func hMultiplier(_ alignment: HorizontalAlignment) -> CGFloat {
        PortAlignmentRegistry.position(of: alignment)
    }

    static func vMultiplier(_ alignment: VerticalAlignment) -> CGFloat {
        PortAlignmentRegistry.position(of: alignment)
    }

    static func makeNodes(_ view: any View, proposal: ProposedSize) -> [LayoutNode] {
        let context = PortGraphContext.shared
        return _openExistentialAndMake(view, proposal: proposal, context: context)
    }

    private static func _openExistentialAndMake<V: View>(_ view: V, proposal: ProposedSize,
                                                         context: PortGraphContext) -> [LayoutNode] {
        context.makeNodes(view, proposal: proposal)
    }

    /// `Text` → engine text node. Apple's `Font`/`Color` storage is opaque (`AnyFontBox`,
    /// `AnyColorBox`), so the first slice renders in the environment's type scale; the
    /// modifier-aware path is the next step in docs/RENDERER.md.
    static func node(for text: Text, environment: PortEnvironment) -> LayoutNode {
        let string = text._portString ?? ""
        let port = text._portStorage
        let style = TextStyleDescriptor(size: port?.font?.size ?? environment.font?.size ?? environment.defaultFontSize,
                                        weight: port?.weight ?? port?.font.map { textWeight($0.weight) } ?? environment.fontWeight,
                                        color: port?.color ?? environment.foreground)
        return LayoutNode.text(string, style: style, lineLimit: environment.lineLimit)
    }

    /// Apple's `Font.Weight` is an opaque struct; its standard members are the identity we need.
    static func textWeight(_ weight: Font.Weight) -> TextStyleDescriptor.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// Reads a stored property of a generic modifier struct by label (the port cannot name the
    /// generic parameters `_BackgroundModifier<Background>` and friends introduce).
    static func child<T>(of value: Any, named label: String, as type: T.Type) -> T? {
        Mirror(reflecting: value).children.first { $0.label == label }?.value as? T
    }

    static func edgeInsets(_ layout: _PaddingLayout) -> EdgeInsetsLike {
        if let insets = layout.insets {
            var result = EdgeInsetsLike(top: insets.top, bottom: insets.bottom,
                                        leading: insets.leading, trailing: insets.trailing)
            if !layout.edges.contains(.top) { result.top = 0 }
            if !layout.edges.contains(.bottom) { result.bottom = 0 }
            if !layout.edges.contains(.leading) { result.leading = 0 }
            if !layout.edges.contains(.trailing) { result.trailing = 0 }
            return result
        }
        return EdgeInsetsLike(16)
    }
}

// MARK: - Tuple content (SwiftUI's variadic builder product)
//
// `VStack { … }` funnels its children into `TupleContent<each Content>`, a parameter pack. The
// engine walks the pack with a `repeat` statement and materialises each element in order.

extension TupleContent: _PortRenderable where repeat each Content: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        var nodes: [LayoutNode] = []
        repeat nodes.append(contentsOf: context.makeNodes(each content, proposal: proposal))
        return nodes
    }
}
