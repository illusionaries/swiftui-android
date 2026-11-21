// PortControls.swift — the gallery demo's controls, on Apple's own declarations.
//
// Each type below keeps its state in storage the generator injects (port-impl/storage.txt) and is
// initialised by bodies that port-impl/bodies.txt supplies, because Apple's interface only
// declares those initialisers. What is left for this file is behaviour: turn the value into engine
// nodes, and turn touches back into writes through the control's `Binding`.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import FoundationShims

// MARK: - Shared control styling
//
// One tabular set of colours so the controls look like one family: iOS uses the same secondary
// fill for tracks and the same accent for every active element.

enum PortControlStyle {
    static func track(_ environment: PortEnvironment) -> RGBAColor {
        environment.isDark ? RGBAColor(hex: 0x48484A) : RGBAColor(hex: 0xDCDCE1)
    }

    static func fill(_ environment: PortEnvironment) -> RGBAColor {
        environment.isDark ? RGBAColor(hex: 0x2C2C2E) : RGBAColor(hex: 0xFFFFFF)
    }

    static func divider(_ environment: PortEnvironment) -> RGBAColor {
        environment.isDark ? RGBAColor(hex: 0x38383A) : RGBAColor(hex: 0xE5E5EA)
    }

    static func knob(_ environment: PortEnvironment) -> RGBAColor {
        RGBAColor(hex: 0xFFFFFF)
    }

    static var secondary: RGBAColor { RGBAColor(hex: 0x8E8E93) }

    /// A text node in the environment's type scale, unless a size is given.
    static func label(_ text: String, environment: PortEnvironment,
                      size: CGFloat? = nil,
                      weight: TextStyleDescriptor.Weight? = nil,
                      color: RGBAColor? = nil) -> LayoutNode {
        let resolvedSize = size ?? environment.font?.size ?? environment.defaultFontSize
        return LayoutNode.text(text,
                               style: TextStyleDescriptor(size: resolvedSize,
                                                          weight: weight ?? environment.fontWeight,
                                                          color: color ?? environment.foreground))
    }

    /// Writes a value back through a binding and asks for the next frame.
    static func write(_ apply: () -> Void) {
        apply()
        PortStateStore.markDirty()
    }
}

// MARK: - Slider

extension Slider: _PortRenderable where Label: View, ValueLabel: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let environment = context.environment
        let lower = _portRange.lowerBound
        let upper = _portRange.upperBound
        let span = max(upper - lower, .leastNonzeroMagnitude)
        let fraction = CGFloat(min(max((_portValue - lower) / span, 0), 1))

        var slider = LayoutNode(.sliderTrack(fraction: fraction,
                                             track: PortControlStyle.track(environment),
                                             fill: environment.accentColor,
                                             knob: PortControlStyle.knob(environment)))
            .onDrag { point, frame in
                // The engine hands over the node's placed frame, so the same geometry the painter
                // used maps the finger onto the track — the knob stays under the finger.
                let geometry = PortSliderGeometry(frame: frame)
                var value = lower + Double(geometry.fraction(atX: point.x)) * span
                if let step = _portStep, step > 0 {
                    value = (value / step).rounded() * step
                }
                let clamped = min(max(value, lower), upper)
                PortControlStyle.write { _portSetValue?(clamped) }
            }
        // A slider is a wide, short control: pin the height, and let the frame claim the row width.
        slider = LayoutNode.frame(FrameSpec(minHeight: 27, idealHeight: 27, maxHeight: 27,
                                            horizontalAlignment: 0.5, verticalAlignment: 0.5),
                                  slider)
        let stretched = LayoutNode.frame(FrameSpec(maxWidth: .infinity, maxHeight: 27,
                                                   horizontalAlignment: 0.5, verticalAlignment: 0.5),
                                         slider)

        var row: [LayoutNode] = []
        if ObjectIdentifier(ValueLabel.self) != ObjectIdentifier(EmptyView.self), let label = _portMinLabel {
            row.append(context.makeNode(label, proposal: proposal))
        }
        row.append(stretched)
        if ObjectIdentifier(ValueLabel.self) != ObjectIdentifier(EmptyView.self), let label = _portMaxLabel {
            row.append(context.makeNode(label, proposal: proposal))
        }
        return row.count == 1
            ? row
            : [LayoutNode.hstack(spacing: 8, horizontalAlignment: 0.5, verticalAlignment: 0.5, row)]
    }
}

// MARK: - Stepper

extension Stepper: _PortRenderable where Label: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let environment = context.environment

        func button(_ glyph: String, _ action: (() -> Void)?) -> LayoutNode {
            let text = PortControlStyle.label(glyph, environment: environment, size: 20,
                                              weight: .medium, color: environment.accentColor)
            let padded = LayoutNode.padding(EdgeInsetsLike(top: 5, bottom: 5, leading: 14, trailing: 14), text)
            let plate = LayoutNode(.shape(.rectangle, fill: .color(PortControlStyle.divider(environment)), stroke: nil))
            let plateSized = LayoutNode.frame(FrameSpec(minHeight: 34, maxHeight: 34), plate)
            let node = LayoutNode.background(plateSized, padded)
            guard let action else { return node }
            return node.onTap { PortControlStyle.write(action) }
        }

        let minus = button("\u{2212}", _portDecrement)
        let plus = button("+", _portIncrement)
        let pair = LayoutNode(.clip(cornerRadius: 8),
                              children: [LayoutNode.hstack(spacing: 1, horizontalAlignment: 0.5,
                                                           verticalAlignment: 0.5, [minus, plus])])

        var row: [LayoutNode] = []
        if ObjectIdentifier(Label.self) != ObjectIdentifier(EmptyView.self), let label = _portLabel {
            row.append(context.makeNode(label, proposal: proposal))
        }
        row.append(LayoutNode.spacer())
        row.append(pair)
        return [LayoutNode.hstack(spacing: 12, horizontalAlignment: 0.5, verticalAlignment: 0.5, row)]
    }
}

// MARK: - Option tags
//
// `Picker` needs each option's selection value, and `.tag(_:)` is what attaches it. Apple routes
// the value through `_trait(...)` into a private trait table; the port keeps it in a wrapper view
// instead, which also makes it readable when the picker walks its content.

public protocol _PortTagProviding {
    var portTag: AnyHashable { get }
    var portTaggedContent: any View { get }
}

public struct _PortTagged<Content: View, Value: Hashable>: View, _PortRenderable, _PortTagProviding {
    let content: Content
    let value: Value

    public var portTag: AnyHashable { AnyHashable(value) }
    public var portTaggedContent: any View { content }

    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        context.makeNodes(content, proposal: proposal)
    }

    public var body: some View { content }
}

extension View {
    /// Apple implements this in terms of an internal trait table; the port's tags live in
    /// `_PortTagged`, so the declaration is omitted from the generated file and supplied here.
    nonisolated public func tag<V>(_ tag: V, includeOptional: Bool = true) -> some View where V: Hashable {
        _PortTagged(content: self, value: tag)
    }
}

/// A view whose children are a fixed, ordered list: what a `@ViewBuilder` block produces.
///
/// The port cannot enumerate such a view generically — `TupleContent` is a parameter pack and
/// `TupleView`'s tuple is opaque — so the port declares the enumeration for its own types and
/// `PortTaggedFlattening` uses it. Without this, a `Picker` saw its whole content as one option.
public protocol _PortChildList {
    var portChildViews: [any View] { get }
}

extension TupleContent: _PortChildList where repeat each Content: View {
    public var portChildViews: [any View] {
        var views: [any View] = []
        repeat views.append(each content)
        return views
    }
}

extension TupleView: _PortChildList {
    public var portChildViews: [any View] {
        Mirror(reflecting: value).children.compactMap { $0.value as? any View }
    }
}

extension Optional: _PortChildList where Wrapped: View {
    public var portChildViews: [any View] {
        switch self {
        case let .some(wrapped): return [wrapped]
        case .none: return []
        }
    }
}

enum PortTaggedFlattening {
    /// Flattens a `Picker`'s content into (tag, view) pairs.
    static func options(of view: any View) -> [(tag: AnyHashable?, view: any View)] {
        if let tagged = view as? any _PortTagProviding {
            return [(tagged.portTag, tagged.portTaggedContent)]
        }
        if let list = view as? any _PortChildList {
            return list.portChildViews.flatMap { options(of: $0) }
        }
        return [(nil, view)]
    }
}

// MARK: - Picker
//
// Rendered as a segmented control: it is the variant that shows every option at once, which is
// what a control gallery is for.

extension Picker: _PortRenderable where Label: View, Content: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let environment = context.environment
        guard let content = _portContent, let selection = _portSelection else {
            return [LayoutNode(.empty)]
        }
        let current = AnyHashable(selection.wrappedValue)

        if environment.pickerStyle == .inline {
            return [inlinePicker(content: content, selection: selection, proposal: proposal, context: context)]
        }

        var segments: [LayoutNode] = []
        for option in PortTaggedFlattening.options(of: content) {
            let isSelected = option.tag.map { $0 == current } ?? false
            let foreground = isSelected
                ? RGBAColor(hex: 0xFFFFFF)
                : environment.foreground
            let labelNodes = context.withEnvironment({ environment in
                environment.foreground = foreground
                environment.fontWeight = isSelected ? .semibold : .regular
            }, body: {
                [context.makeNode(option.view, proposal: proposal)]
            })
            let label = labelNodes.first ?? LayoutNode(.empty)
            let padded = LayoutNode.padding(EdgeInsetsLike(top: 6, bottom: 6, leading: 10, trailing: 10), label)
            let plate = LayoutNode(.shape(.roundedRectangle(cornerRadius: 7),
                                          fill: .color(isSelected ? environment.accentColor
                                                                  : RGBAColor(hex: 0x000000, alpha: 0)),
                                          stroke: nil))
            let segment = LayoutNode.background(plate, padded)
            if let tag = option.tag, let value = tag.base as? SelectionValue {
                segments.append(segment.onTap {
                    PortControlStyle.write { selection.wrappedValue = value }
                })
            } else {
                segments.append(segment)
            }
        }

        let track = LayoutNode(.shape(.roundedRectangle(cornerRadius: 9),
                                      fill: .color(PortControlStyle.divider(environment)), stroke: nil))
        let row = LayoutNode(.stack(axis: .horizontal,
                                    spacing: 2,
                                    horizontalAlignment: 0.5,
                                    verticalAlignment: 0.5),
                             children: segments)
        let control = LayoutNode.background(track, LayoutNode.padding(2, row))

        var stack: [LayoutNode] = []
        if ObjectIdentifier(Label.self) != ObjectIdentifier(EmptyView.self),
           let label = _portLabel, !environment.labelsHidden {
            stack.append(context.makeNode(label, proposal: proposal))
        }
        stack.append(control)
        return stack.count == 1 ? stack : [LayoutNode.vstack(spacing: 8, horizontalAlignment: 0, stack)]
    }
}

extension Picker {
    /// `.pickerStyle(.inline)`: one row per option with a check mark on the selected one.
    nonisolated func inlinePicker(content: Content, selection: Binding<SelectionValue>,
                                  proposal: ProposedSize, context: PortGraphContext) -> LayoutNode {
        let environment = context.environment
        let current = AnyHashable(selection.wrappedValue)
        var rows: [LayoutNode] = []
        for option in PortTaggedFlattening.options(of: content) {
            let isSelected = option.tag.map { $0 == current } ?? false
            let label = context.makeNode(option.view, proposal: proposal)
            let check = PortControlStyle.label(isSelected ? "\u{2713}" : "",
                                               environment: environment,
                                               size: 14, weight: .semibold,
                                               color: environment.accentColor)
            let row = LayoutNode.hstack(spacing: 8, horizontalAlignment: 0.5, verticalAlignment: 0.5,
                                        [label, LayoutNode.spacer(), check])
            let padded = LayoutNode.padding(EdgeInsetsLike(top: 8, bottom: 8, leading: 2, trailing: 2), row)
            if let tag = option.tag, let value = tag.base as? SelectionValue {
                rows.append(padded.onTap { PortControlStyle.write { selection.wrappedValue = value } })
            } else {
                rows.append(padded)
            }
        }
        return LayoutNode.vstack(spacing: 2, horizontalAlignment: 0, rows)
    }
}

// MARK: - ProgressView

extension ProgressView: _PortRenderable where Label: View, CurrentValueLabel: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let environment = context.environment
        let total = _portTotal > 0 ? _portTotal : 1
        let fraction = CGFloat(min(max((_portValue ?? 0) / total, 0), 1))
        let bar = LayoutNode.frame(FrameSpec(minHeight: 5, maxHeight: 5),
                                   LayoutNode(.progressBar(fraction: fraction,
                                                           track: PortControlStyle.track(environment),
                                                           fill: environment.accentColor)))

        var stack: [LayoutNode] = []
        if ObjectIdentifier(Label.self) != ObjectIdentifier(EmptyView.self), let label = _portLabel {
            stack.append(context.makeNode(label, proposal: proposal))
        }
        stack.append(bar)
        if ObjectIdentifier(CurrentValueLabel.self) != ObjectIdentifier(EmptyView.self),
           let valueLabel = _portCurrentValueLabel {
            stack.append(context.makeNode(valueLabel, proposal: proposal))
        }
        return stack.count == 1 ? stack : [LayoutNode.vstack(spacing: 6, horizontalAlignment: 0, stack)]
    }
}

// MARK: - Label

extension Label: _PortRenderable where Title: View, Icon: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        var row: [LayoutNode] = []
        if let icon = _portIcon {
            row.append(context.makeNode(icon, proposal: proposal))
        }
        if let title = _portTitle, !context.environment.labelsHidden {
            row.append(context.makeNode(title, proposal: proposal))
        }
        guard !row.isEmpty else { return [LayoutNode(.empty)] }
        return row.count == 1 ? row : [LayoutNode.hstack(spacing: 6, verticalAlignment: 0.5, row)]
    }
}

// MARK: - Link
//
// A link is text in the accent colour, and tapping it asks the platform to open the destination
// (`PortLinkOpener`, implemented by the Android runtime with an ACTION_VIEW Intent).

extension Link: _PortRenderable where Label: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let environment = context.environment
        let nodes = context.withEnvironment({ environment in
            environment.foreground = environment.accentColor
        }, body: {
            _portLabel.map { [context.makeNode($0, proposal: proposal)] } ?? []
        })
        guard let destination = _portDestination else { return nodes }
        return nodes.map { $0.onTap { PortLinkOpener.open(destination) } }
    }
}

// MARK: - TextField
//
// Draws the field (text, or the prompt/label as a placeholder, on a rounded plate) and owns the
// editing session: a tap hands the control's frame to the platform editor through `PortTextInput`,
// which puts the system IME on screen; typed text comes back through the same seam and is written
// into the binding, so the field redraws with what the user actually typed.

/// Stable identities for text fields, assigned in render order and reset every frame.
///
/// The platform editor needs an identity that outlives a single `body` evaluation (an editor that
/// gets a fresh id each render would restart, dropping the caret and the IME's composing state).
/// Render order is stable for a stable view tree, which is the same assumption the engine's state
/// and scroll stores already make.
enum PortTextFieldSlots {
    nonisolated(unsafe) private static var cursor = 0

    static func beginFrame() {
        cursor = 0
    }

    static func next() -> Int {
        let slot = cursor
        cursor += 1
        return slot
    }
}

extension TextField: _PortRenderable where Label: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let environment = context.environment
        let slot = PortTextFieldSlots.next()
        let binding = _portText
        let text = binding?.wrappedValue ?? ""
        let isFocused = PortTextInput.focusedSlot == slot

        let content: LayoutNode
        if text.isEmpty {
            // Apple shows the prompt when it has one, and the label otherwise.
            let placeholder: (any View)? = (_portPrompt as (any View)?) ?? (_portLabel as (any View)?)
            let placeholderNodes = context.withEnvironment({ environment in
                environment.foreground = PortControlStyle.secondary
            }, body: {
                placeholder.map { PortAdapters.makeNodes($0, proposal: proposal) } ?? []
            })
            content = placeholderNodes.first ?? LayoutNode(.empty)
        } else {
            content = PortControlStyle.label(text, environment: environment)
        }

        // The platform editor is an invisible native widget: the field has to draw the caret.
        // With no text yet the caret belongs *before* the placeholder (the insertion point is the
        // start of the field), not after it.
        var row: [LayoutNode] = text.isEmpty ? [] : [content]
        if isFocused {
            let caretHeight = (environment.font?.size ?? environment.defaultFontSize) + 3
            row.append(LayoutNode.frame(FrameSpec(minWidth: 2, idealWidth: 2, maxWidth: 2,
                                                minHeight: caretHeight,
                                                idealHeight: caretHeight,
                                                maxHeight: caretHeight),
                                        LayoutNode.color(environment.accentColor)))
        }
        if text.isEmpty {
            row.append(content)
        }
        let contentRow = LayoutNode.frame(FrameSpec(maxWidth: .infinity, horizontalAlignment: 0),
                                          LayoutNode.hstack(spacing: 1, verticalAlignment: 0.5, row))

        // `.textFieldStyle(.plain)` is the variant with no plate and no outline.
        let node: LayoutNode
        if environment.textFieldStyle == .plain {
            let body = LayoutNode.padding(EdgeInsetsLike(top: 6, bottom: 6, leading: 0, trailing: 0),
                                          contentRow)
            node = LayoutNode.frame(FrameSpec(maxWidth: .infinity, horizontalAlignment: 0), body)
        } else {
            let padded = LayoutNode.padding(EdgeInsetsLike(top: 9, bottom: 9, leading: 11, trailing: 11),
                                            contentRow)
            // A field with no binding cannot receive text; painting its outline red makes that a
            // visible port defect instead of a tap that silently does nothing.
            let strokeColor = binding == nil ? RGBAColor(hex: 0xFF3B30)
                           : isFocused ? environment.accentColor
                           : PortControlStyle.divider(environment)
            let plate = LayoutNode(.shape(.roundedRectangle(cornerRadius: 9),
                                          fill: .color(PortControlStyle.fill(environment)),
                                          stroke: (width: isFocused ? 2 : 1, color: strokeColor)))
            // Apple's text field is horizontally flexible: it takes the row's width, not its text's.
            node = LayoutNode.frame(FrameSpec(maxWidth: .infinity, horizontalAlignment: 0),
                                    LayoutNode.background(plate, padded))
        }

        // The tap is attached even when the field has no binding: a field that cannot accept
        // text is a rendering problem to see, not a touch target to silently lose.
        guard let binding else { return [node] }
        // Re-entering with the same closures matters: `beginEditing` adopts the newest callbacks,
        // so a refresh that passed a no-op handler would swallow everything the user types.
        let onText: (String) -> Void = { newText in
            binding.wrappedValue = newText
            PortStateStore.markDirty()
        }
        let onEnd: () -> Void = {
            PortStateStore.markDirty()
        }

        // A live session only needs its frame refreshed: layout may have scrolled under it.
        if isFocused {
            PortTextInput.beginEditing(slot: slot, text: text, frame: node.frame,
                                       onText: onText, onEnd: onEnd)
            return [node]
        }
        return [node.onTap {
            PortTextInput.beginEditing(slot: slot,
                                       text: binding.wrappedValue,
                                       frame: node.frame,
                                       onText: onText,
                                       onEnd: onEnd)
            PortStateStore.markDirty()
        }]
    }
}
