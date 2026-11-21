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
        let environment = context.environment
        // The label is drawn in whatever colour the style asks for, so each variant renders the
        // label *inside* the style's environment instead of repainting text afterwards.
        let style = PortButtonStyleRendering.describe(environment.buttonStyle, environment)
        let content = context.withEnvironment({ environment in
            environment.foreground = style.foreground
        }, body: {
            [context.makeNode(label, proposal: proposal)]
        })
        var body = content.first ?? LayoutNode(.empty)
        if let plate = style.plate {
            // Chrome needs breathing room: the backdrop is drawn behind a padded label, so the
            // border does not sit on the glyphs.
            let padded = LayoutNode.padding(EdgeInsetsLike(top: 7, bottom: 7, leading: 15, trailing: 15), body)
            body = LayoutNode.background(plate, padded)
        }

        guard let action = _portAction else { return [body] }
        // Taps are delivered on the UI thread, which is also where the engine renders. The
        // engine hit-tests on `action` (LayoutNode.onTap), not on the `.tap` kind.
        return [body.onTap { MainActor.assumeIsolated { action() } }]
    }
}

/// What each built-in button style looks like.
///
/// Apple draws `.bordered` / `.borderedProminent` in `BorderedButtonStyle.makeBody`, which ships
/// only as a declaration, so the port draws equivalents: the label colour, and an optional plate
/// drawn behind a padded label.
enum PortButtonStyleRendering {
    struct Rendering {
        let foreground: RGBAColor
        let plate: LayoutNode?
    }

    static func describe(_ kind: PortButtonStyleKind, _ environment: PortEnvironment) -> Rendering {
        switch kind {
        case .automatic, .plain, .borderless:
            // No chrome: the label carries the button, in the accent colour (iOS 14+ default).
            return Rendering(foreground: environment.accentColor, plate: nil)
        case .bordered:
            return Rendering(foreground: environment.accentColor,
                             plate: LayoutNode(.shape(.roundedRectangle(cornerRadius: 9),
                                                     fill: .color(RGBAColor(hex: 0x000000, alpha: 0)),
                                                     stroke: (width: 1, color: environment.accentColor))))
        case .borderedProminent:
            return Rendering(foreground: RGBAColor(hex: 0xFFFFFF),
                             plate: LayoutNode(.shape(.roundedRectangle(cornerRadius: 9),
                                                     fill: .color(environment.accentColor),
                                                     stroke: nil)))
        }
    }
}
