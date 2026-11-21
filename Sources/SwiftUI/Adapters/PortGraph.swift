// PortGraph.swift — the render context that binds Apple's declared views to the engine.
//
// Apple's `_GraphValue`, `_ViewInputs` and `_ViewOutputs` are opaque structs: their storage lives
// in Apple's binary, so recompiled from text they are empty. Apple's own engine is context-driven
// too (a `ViewGraph` threads the value), so the port mirrors that shape instead of fighting it:
//
//   • `makeNode(_:)` pushes the view value and its proposed size, calls the type's `_makeView`,
//     and pops the `LayoutNode` the adapter produced;
//   • every `_makeView` implementation reads its own value from the context and ends with
//     `context.finish(node)`, which stashes the result and returns an empty `_ViewOutputs`.
//
// This keeps Apple's declarations byte-identical and needs no generator support.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Environment values the adapters need. Deliberately small: it grows as the port gains widgets.
public struct PortEnvironment: Equatable {
    public var isDark: Bool = false
    public var accentColor: RGBAColor = RGBAColor(hex: 0x0A84FF)
    public var displayScale: CGFloat = 1
    public var defaultFontSize: CGFloat = 17

    public init(isDark: Bool = false,
                accentColor: RGBAColor = RGBAColor(hex: 0x0A84FF),
                displayScale: CGFloat = 1,
                defaultFontSize: CGFloat = 17) {
        self.isDark = isDark
        self.accentColor = accentColor
        self.displayScale = displayScale
        self.defaultFontSize = defaultFontSize
    }
}

public final class PortGraphContext {
    public static let shared = PortGraphContext()

    private var views: [Any] = []
    private var proposals: [ProposedSize] = []
    private var results: [[LayoutNode]] = []

    public var environment = PortEnvironment()

    /// Symbols the last frame reached that are still stubbed — the port's work queue.
    public private(set) var unimplemented: [String] = []

    public init() {}

    // MARK: - Frame lifecycle

    public func beginFrame(environment: PortEnvironment) {
        self.environment = environment
        views.removeAll(keepingCapacity: true)
        proposals.removeAll(keepingCapacity: true)
        results.removeAll(keepingCapacity: true)
        unimplemented.removeAll(keepingCapacity: true)
    }

    public func endFrame() {
        PortDiagnostics.unimplementedHits.append(contentsOf: unimplemented)
    }

    // MARK: - Adapter entry point

    /// Materialises a view into one layout node. Containers call this per child.
    public func makeNode<V: View>(_ view: V, proposal: ProposedSize) -> LayoutNode {
        let nodes = makeNodes(view, proposal: proposal)
        switch nodes.count {
        case 0: return LayoutNode(.empty)
        case 1: return nodes[0]
        default: return LayoutNode(.group, children: nodes)
        }
    }

    /// Materialises a view that expands to several nodes (`TupleView`, `Group`, conditionals).
    public func makeNodes<V: View>(_ view: V, proposal: ProposedSize) -> [LayoutNode] {
        views.append(view)
        proposals.append(proposal)
        _ = V._makeView(view: _GraphValue<V>(), inputs: _ViewInputs())
        views.removeLast()
        proposals.removeLast()
        return results.popLast() ?? []
    }

    // MARK: - Called from `_makeView` implementations

    /// The view value the current `_makeView` call is for.
    public func current<V>(_ type: V.Type) -> V? {
        views.last as? V
    }

    public var currentProposal: ProposedSize {
        proposals.last ?? .unspecified
    }

    @discardableResult
    public func finish(_ node: LayoutNode) -> _ViewOutputs {
        results.append([node])
        return _ViewOutputs()
    }

    @discardableResult
    public func finish(_ nodes: [LayoutNode]) -> _ViewOutputs {
        results.append(nodes)
        return _ViewOutputs()
    }

    public func noteUnimplemented(_ symbol: String) {
        if !unimplemented.contains(symbol) { unimplemented.append(symbol) }
    }
}

// MARK: - `View._makeView` default: evaluate `body`

// Generated stub is omitted via `port-impl/implemented.txt`; this is the port's implementation.
// It covers every `View` that Apple describes in terms of `body`, i.e. all normal app views.
extension View {
    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let context = PortGraphContext.shared
        guard let value = context.current(Self.self) else {
            return context.finish(LayoutNode(.empty))
        }
        let proposal = context.currentProposal
        return context.finish(context.makeNodes(value.body, proposal: proposal))
    }
}
