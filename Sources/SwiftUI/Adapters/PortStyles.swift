// PortStyles.swift — Apple's control styles, applied instead of ignored.
//
// Apple's framework renders a control *through* its style: `.buttonStyle(.borderedProminent)`
// stores a `BorderedProminentButtonStyle` in the environment and the button's view tree asks that
// style to draw it. The declarations for both halves ship in the interface
// (`ButtonStyle`, `BorderedProminentButtonStyle`, `View.buttonStyle(_:)`), but the style *types*
// ship bodyless: their `makeBody`/`_body` members are Apple's binary.
//
// So the port does what it can do honestly. The modifiers are real (they write an environment
// value, like Apple's), the control adapters consult that value, and each built-in style has a
// rendering the port draws itself. A *user-defined* style cannot be supported this way, because its
// drawing lives in `makeBody`, which is Apple's declaration and this project's emptiness — that is
// recorded as a gap in docs/GALLERY.md rather than silently ignored.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import FoundationShims

// MARK: - The style values the adapters understand

public enum PortButtonStyleKind: String {
    case automatic, plain, borderless, bordered, borderedProminent
}

public enum PortToggleStyleKind: String {
    case automatic, switchStyle, buttonStyle
}

public enum PortPickerStyleKind: String {
    case automatic, segmented, inline
}

public enum PortTextFieldStyleKind: String {
    case automatic, plain, roundedBorder
}

public enum PortProgressViewStyleKind: String {
    case automatic, linear
}

// MARK: - Recognition
//
// A style is a value of a concrete type; the type name is the only thing a bodyless style exposes.
// These mappings are the port's statement of "this is what that style looks like".

enum PortStyleRecognition {
    static func buttonStyleName(_ style: Any) -> PortButtonStyleKind {
        let name = String(describing: type(of: style))
        if name.contains("BorderedProminent") { return .borderedProminent }
        if name.contains("Bordered") { return .bordered }
        if name.contains("Borderless") { return .borderless }
        if name.contains("Plain") { return .plain }
        return .automatic
    }

    static func toggleStyleName(_ style: Any) -> PortToggleStyleKind {
        let name = String(describing: type(of: style))
        if name.contains("Switch") { return .switchStyle }
        if name.contains("Button") { return .buttonStyle }
        return .automatic
    }

    static func pickerStyleName(_ style: Any) -> PortPickerStyleKind {
        let name = String(describing: type(of: style))
        if name.contains("Segmented") { return .segmented }
        if name.contains("Inline") || name.contains("Wheel") || name.contains("RadioGroup") || name.contains("Menu") {
            return .inline
        }
        return .automatic
    }

    static func textFieldStyleName(_ style: Any) -> PortTextFieldStyleKind {
        let name = String(describing: type(of: style))
        if name.contains("RoundedBorder") { return .roundedBorder }
        if name.contains("Plain") { return .plain }
        return .automatic
    }

    static func progressViewStyleName(_ style: Any) -> PortProgressViewStyleKind {
        // A circular style would need arc strokes the engine does not have yet; it falls back to
        // the linear rendering rather than dropping the control.
        .linear
    }
}

// MARK: - The modifiers
//
// Each is one wrapper that writes the environment value for its subtree, which is exactly the
// mechanism Apple's modifiers use. They replace the generated stubs (port-impl/implemented.txt).

public struct _PortButtonStyle<Content: View, Style>: View, _PortRenderable {
    let content: Content
    let kind: PortButtonStyleKind

    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        context.withEnvironment({ environment in
            environment.buttonStyle = kind
        }, body: {
            context.makeNodes(content, proposal: proposal)
        })
    }

    public var body: some View { content }
}

public struct _PortToggleStyle<Content: View, Style>: View, _PortRenderable {
    let content: Content
    let kind: PortToggleStyleKind

    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        context.withEnvironment({ environment in
            environment.toggleStyle = kind
        }, body: {
            context.makeNodes(content, proposal: proposal)
        })
    }

    public var body: some View { content }
}

public struct _PortPickerStyle<Content: View, Style>: View, _PortRenderable {
    let content: Content
    let kind: PortPickerStyleKind

    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        context.withEnvironment({ environment in
            environment.pickerStyle = kind
        }, body: {
            context.makeNodes(content, proposal: proposal)
        })
    }

    public var body: some View { content }
}

public struct _PortTextFieldStyle<Content: View, Style>: View, _PortRenderable {
    let content: Content
    let kind: PortTextFieldStyleKind

    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        context.withEnvironment({ environment in
            environment.textFieldStyle = kind
        }, body: {
            context.makeNodes(content, proposal: proposal)
        })
    }

    public var body: some View { content }
}

public struct _PortProgressViewStyle<Content: View, Style>: View, _PortRenderable {
    let content: Content
    let kind: PortProgressViewStyleKind

    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        context.withEnvironment({ environment in
            environment.progressViewStyle = kind
        }, body: {
            context.makeNodes(content, proposal: proposal)
        })
    }

    public var body: some View { content }
}

extension View {
    public func buttonStyle<S>(_ style: S) -> some View where S: ButtonStyle {
        _PortButtonStyle<Self, S>(content: self, kind: PortStyleRecognition.buttonStyleName(style))
    }

    public func buttonStyle<S>(_ style: S) -> some View where S: PrimitiveButtonStyle {
        _PortButtonStyle<Self, S>(content: self, kind: PortStyleRecognition.buttonStyleName(style))
    }

    public func toggleStyle<S>(_ style: S) -> some View where S: ToggleStyle {
        _PortToggleStyle<Self, S>(content: self, kind: PortStyleRecognition.toggleStyleName(style))
    }

    public func pickerStyle<S>(_ style: S) -> some View where S: PickerStyle {
        _PortPickerStyle<Self, S>(content: self, kind: PortStyleRecognition.pickerStyleName(style))
    }

    public func textFieldStyle<S>(_ style: S) -> some View where S: TextFieldStyle {
        _PortTextFieldStyle<Self, S>(content: self, kind: PortStyleRecognition.textFieldStyleName(style))
    }

    public func progressViewStyle<S>(_ style: S) -> some View where S: ProgressViewStyle {
        _PortProgressViewStyle<Self, S>(content: self, kind: PortStyleRecognition.progressViewStyleName(style))
    }
}
