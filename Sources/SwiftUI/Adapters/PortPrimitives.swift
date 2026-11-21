// PortPrimitives.swift — how the port's engine renders SwiftUI's built-in views.
//
// Each conformance reads the value Apple's interface exposes (their internal storage is public in
// the interface) and produces engine nodes. Nothing here re-declares API: the declarations stay in
// Generated/, and this file supplies only the behaviour Apple's binary would have provided.
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
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

        if let frame = modifier as? _FrameLayout {
            let spec = FrameSpec(minWidth: frame.width, idealWidth: frame.width, maxWidth: frame.width,
                                 minHeight: frame.height, idealHeight: frame.height, maxHeight: frame.height,
                                 horizontalAlignment: PortAdapters.hMultiplier(frame.alignment.horizontal),
                                 verticalAlignment: PortAdapters.vMultiplier(frame.alignment.vertical))
            let child = context.makeNode(content, proposal: proposal)
            return [LayoutNode.frame(spec, child)]
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
        let string: String
        switch text.storage {
        case let .verbatim(value):
            string = value
        default:
            string = ""
        }
        let style = TextStyleDescriptor(size: environment.defaultFontSize,
                                        weight: .regular,
                                        color: environment.isDark ? .white : RGBAColor(hex: 0x111114))
        return LayoutNode.text(string, style: style)
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
