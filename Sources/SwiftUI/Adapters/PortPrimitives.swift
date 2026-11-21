// PortPrimitives.swift — `_makeView` implementations for the first slice of SwiftUI's primitives.
//
// Each implementation reads the view value Apple's interface exposes (their internal storage is
// public in the interface) and produces the corresponding engine node. Nothing here re-declares
// API: the declarations stay in Generated/, and this file only supplies the bodies that Apple's
// binary would have provided.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import FoundationShims

// MARK: - Text

extension Text {
    public static func _makeView(view: _GraphValue<Text>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let text = context.current(Text.self) else {
            return context.finish(LayoutNode(.empty))
        }
        return context.finish(PortAdapters.node(for: text, environment: context.environment))
    }
}

// MARK: - Leaf views

extension EmptyView {
    public static func _makeView(view: _GraphValue<EmptyView>, inputs: _ViewInputs) -> _ViewOutputs {
        PortGraphContext.shared.finish(LayoutNode(.empty))
    }
}

extension Spacer {
    public static func _makeView(view: _GraphValue<Spacer>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        let length = context.current(Spacer.self)?.minLength ?? 0
        return context.finish(LayoutNode.spacer(minLength: length))
    }
}

// MARK: - Stacks

extension VStack {
    public static func _makeView(view: _GraphValue<VStack<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let stack = context.current(VStack<Content>.self) else {
            return context.finish(LayoutNode(.empty))
        }
        let proposal = context.currentProposal
        let children = context.makeNodes(stack._tree.content, proposal: proposal)
        let spacing = stack._tree.root.spacing ?? PortAdapters.defaultStackSpacing
        return context.finish(LayoutNode(.stack(axis: .vertical, spacing: spacing,
                                                horizontalAlignment: PortAdapters.hMultiplier(stack._tree.root.alignment),
                                                verticalAlignment: 0.5), children: children))
    }
}

extension HStack {
    public static func _makeView(view: _GraphValue<HStack<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let stack = context.current(HStack<Content>.self) else {
            return context.finish(LayoutNode(.empty))
        }
        let children = context.makeNodes(stack._tree.content, proposal: context.currentProposal)
        let spacing = stack._tree.root.spacing ?? PortAdapters.defaultStackSpacing
        return context.finish(LayoutNode(.stack(axis: .horizontal, spacing: spacing,
                                                horizontalAlignment: 0.5,
                                                verticalAlignment: PortAdapters.vMultiplier(stack._tree.root.alignment)),
                                         children: children))
    }
}

extension ZStack {
    public static func _makeView(view: _GraphValue<ZStack<Content>>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let stack = context.current(ZStack<Content>.self) else {
            return context.finish(LayoutNode(.empty))
        }
        let children = context.makeNodes(stack._tree.content, proposal: context.currentProposal)
        return context.finish(LayoutNode(.zstack(horizontalAlignment: PortAdapters.hMultiplier(stack._tree.root.alignment.horizontal),
                                                verticalAlignment: PortAdapters.vMultiplier(stack._tree.root.alignment.vertical)),
                                         children: children))
    }
}

// MARK: - Tuples, groups, conditionals

extension TupleView {
    public static func _makeView(view: _GraphValue<TupleView<T>>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let tuple = context.current(TupleView<T>.self) else {
            return context.finish([])
        }
        let proposal = context.currentProposal
        var nodes: [LayoutNode] = []
        let mirror = Mirror(reflecting: tuple.value)
        for child in mirror.children {
            guard let anyView = child.value as? any View else { continue }
            nodes.append(contentsOf: PortAdapters.makeNodes(anyView, proposal: proposal))
        }
        return context.finish(nodes)
    }
}

extension Optional where Wrapped: View {
    public static func _makeView(view: _GraphValue<Optional<Wrapped>>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let value = context.current(Optional<Wrapped>.self) else {
            return context.finish(LayoutNode(.empty))
        }
        switch value {
        case let .some(wrapped):
            return context.finish(context.makeNodes(wrapped, proposal: context.currentProposal))
        case .none:
            return context.finish(LayoutNode(.empty))
        }
    }
}

// MARK: - Layout modifiers

// One generic witness for every `ModifiedContent`, switching on the modifier's type at runtime.
// Constrained extensions cannot witness a protocol requirement for the unconstrained type.
extension ModifiedContent where Content: View, Modifier: ViewModifier {
    public static func _makeView(view: _GraphValue<ModifiedContent<Content, Modifier>>,
                                 inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let modified = context.current(ModifiedContent<Content, Modifier>.self) else {
            return context.finish(LayoutNode(.empty))
        }
        let proposal = context.currentProposal
        let modifier = modified.modifier

        if let padding = modifier as? _PaddingLayout {
            let insets = PortAdapters.edgeInsets(padding)
            let child = context.makeNode(modified.content,
                                         proposal: ProposedSize(width: proposal.width.map { max(0, $0 - insets.leading - insets.trailing) },
                                                                height: proposal.height.map { max(0, $0 - insets.top - insets.bottom) }))
            return context.finish(LayoutNode.padding(insets, child))
        }

        if let frame = modifier as? _FrameLayout {
            let spec = FrameSpec(minWidth: frame.width, idealWidth: frame.width, maxWidth: frame.width,
                                 minHeight: frame.height, idealHeight: frame.height, maxHeight: frame.height,
                                 horizontalAlignment: PortAdapters.hMultiplier(frame.alignment.horizontal),
                                 verticalAlignment: PortAdapters.vMultiplier(frame.alignment.vertical))
            let child = context.makeNode(modified.content, proposal: proposal)
            return context.finish(LayoutNode.frame(spec, child))
        }

        // Unknown modifier for now: draw the content unchanged and record the symbol so the gap is
        // visible in PortDiagnostics rather than silently disappearing.
        context.noteUnimplemented("modifier \(String(reflecting: Modifier.self))")
        return context.finish(context.makeNode(modified.content, proposal: proposal))
    }
}

// MARK: - Helpers bridging Apple's values to engine values

enum PortAdapters {
    static let defaultStackSpacing: CGFloat = 8

    /// Apple's alignment types are opaque; their identity is expressed by the static members
    /// Apple declares (`.leading`, `.center`, `.trailing`, …), so map by equality.
    static func hMultiplier(_ alignment: HorizontalAlignment) -> CGFloat {
        if alignment == .leading { return 0 }
        if alignment == .trailing { return 1 }
        return 0.5
    }

    static func vMultiplier(_ alignment: VerticalAlignment) -> CGFloat {
        if alignment == .top { return 0 }
        if alignment == .bottom { return 1 }
        return 0.5
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
    /// `AnyColorBox`), so the first slice renders with the environment's type scale; the
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

// MARK: - Text initializers
//
// `Text("…")` funnels through these; Apple's bodies are in its binary. Both simply store the
// string in `Text.Storage.verbatim`, which is what Apple's `init(verbatim:)` does inlinably.

extension Text {
    // `@_disfavoredOverload` is Apple's own ranking on this initializer: string literals prefer
    // the LocalizedStringKey/LocalizedStringResource overloads, and generated @inlinable bodies
    // rely on that ordering.
    @_disfavoredOverload
    public init<S>(_ content: S) where S: StringProtocol {
        self.init(verbatim: String(content))
    }

    /// Apple declares this overload in its SwiftUI interface; it is not present in the retargeted
    /// one (the two interfaces split the `Text` initializers and R10 keeps a single witness per
    /// spelling). Generated `@inlinable` bodies call it, so the port supplies it.
    public init(_ resource: FoundationShims.LocalizedStringResource) {
        self.init(verbatim: String(describing: resource))
    }
}
