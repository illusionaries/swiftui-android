// PortButton.swift — buttons, and the tap that runs their action.
//
// `Button` recompiles to an empty struct (Apple's interface hides its storage), so the generator
// injects `_portAction` / `_portLabel` into the declaration (port-impl/storage.txt). Everything
// else is Apple's: the initialisers keep their exact signatures and the label builder stays a
// `@ContentBuilder`.
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#else
import Foundation
#endif

extension Button {
    public init(action: @escaping @MainActor () -> Void, @ContentBuilder label: () -> Label) {
        self._portAction = action
        self._portLabel = label()
    }
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {
        self._portAction = action
        self._portLabel = Text(titleKey)
    }

    @_disfavoredOverload
    public init<S>(_ title: S, action: @escaping @MainActor () -> Void) where S: StringProtocol {
        self._portAction = action
        self._portLabel = Text(verbatim: String(title))
    }
}

extension Button: _PortRenderable where Label: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        guard let label = _portLabel else { return [] }
        let content = context.makeNode(label, proposal: proposal)
        guard let action = _portAction else { return [content] }
        // Taps are delivered on the UI thread, which is also where the engine renders. The
        // engine hit-tests on `action` (LayoutNode.onTap), not on the `.tap` kind.
        return [content.onTap { MainActor.assumeIsolated { action() } }]
    }
}
