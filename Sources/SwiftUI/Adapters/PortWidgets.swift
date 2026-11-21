// PortWidgets.swift — the remaining view primitives the Atlas demo needs.
//
// Each type below hides some or all of its storage in Apple's interface; where the storage is
// visible it is used directly, and where it is hidden the generator injects it
// (port-impl/storage.txt) or the port keeps it in a port-owned box.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import FoundationShims

// MARK: - Conditional content (if/else in a ViewBuilder)

extension _ConditionalContent: _PortRenderable where TrueContent: View, FalseContent: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        switch storage {
        case let .trueContent(content): return context.makeNodes(content, proposal: proposal)
        case let .falseContent(content): return context.makeNodes(content, proposal: proposal)
        }
    }
}

// MARK: - Group

extension Group: _PortRenderable where Content: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        context.makeNodes(content, proposal: proposal)
    }
}

// MARK: - Image
//
// Android has no SF Symbols. Icons are mapped onto their closest text glyph so the layout and the
// visual rhythm of a screen survive; `Image` keeps its identity in a port-owned provider box.

final class PortImageBox: AnyImageProviderBox {
    let systemName: String

    init(systemName: String) {
        self.systemName = systemName
    }
}

enum PortSymbolGlyphs {
    /// SF Symbol name → the character drawn instead. Deliberately conservative: only symbols the
    /// demos use, plus the ones whose glyph is unambiguous.
    static func glyph(for symbol: String) -> String {
        switch symbol {
        case "chevron.right": return "›"
        case "chevron.left": return "‹"
        case "chevron.down": return "⌄"
        case "chevron.up": return "⌃"
        case "arrow.right": return "→"
        case "arrow.left": return "←"
        case "star": return "☆"
        case "star.fill": return "★"
        case "magnifyingglass": return "⌕"
        case "heart", "heart.fill": return "♥"
        case "bookmark", "bookmark.fill": return "▮"
        case "square.and.arrow.up": return "↑"
        case "clock": return "◷"
        case "person", "person.fill": return "◉"
        case "checkmark": return "✓"
        case "xmark": return "✕"
        case "plus": return "+"
        default: return "•"
        }
    }
}

extension Image {
    public init(systemName: String) {
        self.provider = PortImageBox(systemName: systemName)
    }
}

extension Image: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let name = (provider as? PortImageBox)?.systemName ?? ""
        let style = TextStyleDescriptor(size: context.environment.font?.size ?? 16,
                                        weight: .regular,
                                        color: context.environment.foreground)
        return [LayoutNode.text(PortSymbolGlyphs.glyph(for: name), style: style)]
    }
}

// MARK: - Toggle

extension Toggle {
    public init(isOn: Binding<Bool>, @ContentBuilder label: () -> Label) {
        self._portIsOn = isOn
        self._portLabel = label()
    }
}

extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {
        self._portIsOn = isOn
        self._portLabel = Text(titleKey)
    }

    @_disfavoredOverload
    public init<S>(_ title: S, isOn: Binding<Bool>) where S: StringProtocol {
        self._portIsOn = isOn
        self._portLabel = Text(verbatim: String(title))
    }
}

extension Toggle: _PortRenderable where Label: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let isOn = _portIsOn?.wrappedValue ?? false
        let label = _portLabel.map { context.makeNode($0, proposal: proposal) } ?? LayoutNode(.empty)

        let track = LayoutNode(.shape(.capsule,
                                      fill: .color(isOn ? context.environment.accentColor
                                                        : RGBAColor(hex: 0xE5E5EA)),
                                      stroke: nil))
        let trackFixed = LayoutNode.frame(FrameSpec(minWidth: 51, maxWidth: 51), track)
        let knob = LayoutNode.frame(FrameSpec.width(27),
                                    LayoutNode(.shape(.circle, fill: .color(RGBAColor(hex: 0xFFFFFF)), stroke: nil)))
        let switchBody = LayoutNode(.zstack(horizontalAlignment: isOn ? 0.85 : 0.15, verticalAlignment: 0.5),
                                    children: [trackFixed, knob])
        return [LayoutNode(.stack(axis: .horizontal, spacing: 12, horizontalAlignment: 0, verticalAlignment: 0.5),
                           children: [label, switchBody])]
            .map { node in
                _portIsOn.map { binding in
                    node.onTap {
                        binding.wrappedValue.toggle()
                        PortStateStore.markDirty()
                    }
                } ?? node
            }
    }
}

// MARK: - onTapGesture
//
// The engine's tap is a node action, so the modifier wraps the value in a view the engine can
// render with an action attached.

public struct _PortTappable<Content: View>: View, _PortRenderable {
    let content: Content
    let action: () -> Void

    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        [context.makeNode(content, proposal: proposal).onTap { action() }]
    }

    public var body: some View { content }
}

extension View {
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View {
        _PortTappable(content: self, action: action)
    }
}

/// Layout-neutral modifiers Apple defines in terms of its own internals: the port returns the
/// value unchanged, which is what "hidden label" means for a renderer with no label chrome.
extension View {
    public func labelsHidden() -> some View { self }
}

// MARK: - accentColor

extension Color {
    public static var accentColor: Color { ._port(RGBAColor(hex: 0x0A84FF)) }
}

// MARK: - Observable state objects
//
// `@StateObject` keeps the object alive for the lifetime of the view; `@ObservedObject` reads an
// object its owner holds. The port never needs change notifications because it re-evaluates the
// view tree every frame — what it does need is stable storage, which the slot store provides.

/// Object storage for `@StateObject`.
///
/// The view struct — and with it the wrapper — is rebuilt every frame, so an object needs an
/// identity that survives that. `StateObject`'s initialiser takes a slot id: initialisers run once
/// per wrapper per frame in a fixed order, whereas *reads* of `wrappedValue` happen many times
/// (label, conditional, child views). Keying by read order gave each read its own object — the tab
/// bar showed one model while the screen's conditional saw another.
public enum PortObjectStore {
    nonisolated(unsafe) private static var cursor = 0
    nonisolated(unsafe) private static var objects: [Int: AnyObject] = [:]

    public static func beginFrame() {
        cursor = 0
    }

    /// Called from `StateObject.init` once per wrapper per frame.
    static func reserveSlot() -> Int {
        let slot = cursor
        cursor += 1
        return slot
    }

    static func object<Object: AnyObject>(at slot: Int, create: () -> Object) -> Object {
        if let existing = objects[slot] as? Object { return existing }
        let created = create()
        if slot >= 0 { objects[slot] = created }
        return created
    }
}

extension ObservedObject.Wrapper {
    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
        Binding(get: { self.root[keyPath: keyPath] },
                set: { self.root[keyPath: keyPath] = $0 })
    }
}

// MARK: - StateObject
//
// The wrapper is rebuilt every frame, so the object needs an identity that survives: the
// initialiser reserves a slot (initialisers run once per wrapper per frame, in a fixed order) and
// every `wrappedValue` read of that wrapper uses it. Keying by *read* order instead gave each read
// its own object — the tab bar showed one model while the root view's conditional saw another.

extension StateObject {
    @MainActor public init(wrappedValue value: ObjectType) {
        let boxed = value
        self.storage = .initially { boxed }
        self._portSlot = PortObjectStore.reserveSlot()
    }

    @_disfavoredOverload
    @MainActor public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {
        self.storage = .initially(thunk)
        self._portSlot = PortObjectStore.reserveSlot()
    }

}
