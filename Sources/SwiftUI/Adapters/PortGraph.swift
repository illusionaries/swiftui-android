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
    /// Set by `.font(...)`; nil means "the default type scale".
    public var font: PortFontSpec?
    /// Set by `.lineLimit(...)`; nil means "as many lines as it takes".
    public var lineLimit: Int?
    /// Set by `.foregroundStyle(...)` / `.foregroundColor(...)`.
    public var foreground: RGBAColor
    /// Default text weight, raised by `.bold()` / `.fontWeight(...)`.
    public var fontWeight: TextStyleDescriptor.Weight
    /// Set by `.labelsHidden()`: controls drop their label text and keep only their control body,
    /// which is what the modifier means in Apple's environment.
    public var labelsHidden: Bool

    public init(isDark: Bool = false,
                accentColor: RGBAColor = RGBAColor(hex: 0x0A84FF),
                displayScale: CGFloat = 1,
                defaultFontSize: CGFloat = 17,
                font: PortFontSpec? = nil,
                lineLimit: Int? = nil,
                foreground: RGBAColor? = nil,
                fontWeight: TextStyleDescriptor.Weight = .regular,
                labelsHidden: Bool = false) {
        self.isDark = isDark
        self.accentColor = accentColor
        self.displayScale = displayScale
        self.defaultFontSize = defaultFontSize
        self.font = font
        self.lineLimit = lineLimit
        self.foreground = foreground ?? (isDark ? RGBAColor(hex: 0xF2F2F7) : RGBAColor(hex: 0x111114))
        self.fontWeight = fontWeight
        self.labelsHidden = labelsHidden
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
        PortStateStore.beginFrame()
        PortScrollStore.beginFrame()
        PortObjectStore.beginFrame()
        PortTextFieldSlots.beginFrame()
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
    ///
    /// Primitives conform to `_PortRenderable`, which the engine dispatches to directly. Anything
    /// else is an app-defined view, materialised by evaluating its `body` — the same contract
    /// Apple's `View._makeView` has, without depending on a witness table entry.
    public func makeNodes<V: View>(_ view: V, proposal: ProposedSize) -> [LayoutNode] {
        if let renderable = view as? any _PortRenderable {
            return renderable._portMakeNodes(proposal: proposal, context: self)
        }
        views.append(view)
        proposals.append(proposal)
        let nodes = makeNodes(view.body, proposal: proposal)
        views.removeLast()
        proposals.removeLast()
        return nodes
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

    /// Runs `body` with a tweaked environment (how style modifiers scope their values).
    public func withEnvironment(_ tweak: (inout PortEnvironment) -> Void,
                                body: () -> [LayoutNode]) -> [LayoutNode] {
        let saved = environment
        tweak(&environment)
        defer { environment = saved }
        return body()
    }

    public func noteUnimplemented(_ symbol: String) {
        if !unimplemented.contains(symbol) { unimplemented.append(symbol) }
    }
}

// MARK: - Primitives the engine renders itself

/// A view the port renders directly, instead of through `View._makeView`.
///
/// Existential dispatch keeps the engine independent of Apple's graph witness tables (whose
/// storage is in their binary) and makes adding a primitive a one-file change.
public protocol _PortRenderable {
    nonisolated func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode]
}

// MARK: - `View._makeView` default: evaluate `body`

// Generated stub is omitted via `port-impl/implemented.txt`; this is the port's implementation.
// It covers every `View` that Apple describes in terms of `body`, i.e. all normal app views.
extension View {
    nonisolated public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        if PortDiagnostics.verbose { PortDiagnostics.log("default _makeView for \(Self.self)") }
        let context = PortGraphContext.shared
        guard let value = context.current(Self.self) else {
            return context.finish(LayoutNode(.empty))
        }
        let proposal = context.currentProposal
        return context.finish(context.makeNodes(value.body, proposal: proposal))
    }
}

// The graph shells keep their implicit internal initializers: the port never stores anything in
// them (the state lives in `PortGraphContext`), so R11 must not synthesize a trapping public
// `init()`. Their symbols are listed in `port-impl/implemented.txt` for exactly that reason.
