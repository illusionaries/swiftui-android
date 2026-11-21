// Node.swift — the port's layout tree: measure → place → paint.
//
// This is where the port's engine lives. Apple's declared views will be lowered into these
// nodes by the `_makeView` adapters (Engine/ViewGraph.swift). Keeping the tree, the layout
// algorithm and the painting pass free of platform calls is what makes the whole engine
// unit-testable on the host.
//
// Layout discipline matches SwiftUI's: a parent proposes a size, a child answers with its own
// size, and only the parent decides where the child goes. Units are points (dp).

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

// MARK: - Supporting types

public enum StackAxis: Equatable {
    case horizontal
    case vertical
}

public struct EdgeInsetsLike: Equatable {
    public var top: CGFloat
    public var bottom: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, bottom: CGFloat = 0, leading: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }

    public static let zero = EdgeInsetsLike()

    public init(_ all: CGFloat) {
        self.init(top: all, bottom: all, leading: all, trailing: all)
    }
}

public struct TextSpec: Equatable {
    public var text: String
    public var style: TextStyleDescriptor
    public var lineLimit: Int?
    public var alignment: CGFloat   // 0 = leading, 0.5 = center, 1 = trailing

    public init(text: String,
                style: TextStyleDescriptor,
                lineLimit: Int? = nil,
                alignment: CGFloat = 0) {
        self.text = text
        self.style = style
        self.lineLimit = lineLimit
        self.alignment = alignment
    }
}

public struct FrameSpec: Equatable {
    public var minWidth: CGFloat?
    public var idealWidth: CGFloat?
    public var maxWidth: CGFloat?
    public var minHeight: CGFloat?
    public var idealHeight: CGFloat?
    public var maxHeight: CGFloat?
    public var horizontalAlignment: CGFloat   // 0 = leading, 0.5 = center, 1 = trailing
    public var verticalAlignment: CGFloat     // 0 = top, 0.5 = center, 1 = bottom

    public init(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                horizontalAlignment: CGFloat = 0.5, verticalAlignment: CGFloat = 0.5) {
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.idealHeight = idealHeight
        self.maxHeight = maxHeight
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
    }

    public static func width(_ value: CGFloat) -> FrameSpec {
        FrameSpec(minWidth: value, idealWidth: value, maxWidth: value)
    }

    public static func height(_ value: CGFloat) -> FrameSpec {
        FrameSpec(minHeight: value, idealHeight: value, maxHeight: value)
    }
}

public enum PortFillStyle: Equatable {
    case color(RGBAColor)
    case linearGradient([RGBAColor], start: CGPoint, end: CGPoint)
}

public enum ShapeKind: Equatable {
    case rectangle
    case roundedRectangle(cornerRadius: CGFloat)
    case circle
    case capsule
}

// MARK: - Node

public final class LayoutNode {
    public enum Kind {
        case empty
        case text(TextSpec)
        case stack(axis: StackAxis, spacing: CGFloat, horizontalAlignment: CGFloat, verticalAlignment: CGFloat)
        case zstack(horizontalAlignment: CGFloat, verticalAlignment: CGFloat)
        /// Vertical scroll container. Content is laid out once at the viewport width and
        /// shifted by `offset`; painting is clipped to the viewport. Maps to `ScrollView`.
        case scroll(offset: CGFloat)
        case spacer(minLength: CGFloat)
        case fill(PortFillStyle)
        /// Linear value indicator (`ProgressView`): a rounded track with the filled fraction.
        case progressBar(fraction: CGFloat, track: RGBAColor, fill: RGBAColor)
        /// Continuous value control (`Slider`): track, filled fraction and a knob. The geometry is
        /// resolved from the placed frame, so the control is flexible along the horizontal axis.
        case sliderTrack(fraction: CGFloat, track: RGBAColor, fill: RGBAColor, knob: RGBAColor)
        case shape(ShapeKind, fill: PortFillStyle?, stroke: (width: CGFloat, color: RGBAColor)?)
        case padding(EdgeInsetsLike)
        case frame(FrameSpec)
        /// children[0] = content, children[1] = background
        case background
        /// children[0] = content, children[1] = overlay
        case overlay
        case opacity(CGFloat)
        case offset(CGFloat, CGFloat)
        case clip(cornerRadius: CGFloat)
        case shadow(dx: CGFloat, dy: CGFloat, blur: CGFloat, color: RGBAColor, cornerRadius: CGFloat = 0)
        case tap(() -> Void)
        case group
    }

    public var kind: Kind
    public var children: [LayoutNode]
    /// Tap handler attached by the `.onTapGesture` equivalent.
    public var action: (() -> Void)?
    /// Continuous drag handler for controls (sliders). Receives the touch point in the same
    /// coordinate space as `frame`, plus the node's own frame, so the control can map the position
    /// onto its track. Taps on such a node are routed here too (a tap on a slider jumps the value).
    public var dragAction: ((CGPoint, CGRect) -> Void)?
    /// Opaque payload the app can use to identify the tapped node (e.g. a row index).
    public var tag: Int?
    /// Assigned during the place pass, in the coordinate space of the nearest ancestor that
    /// established a coordinate system (the root frame for now).
    public var frame: CGRect = .zero

    private var textLayoutCache: (width: CGFloat?, layout: TextLayout)?
    private var flexCache: Bool?

    public init(_ kind: Kind, children: [LayoutNode] = []) {
        self.kind = kind
        self.children = children
    }

    public convenience init(_ kind: Kind, _ child: LayoutNode) {
        self.init(kind, children: [child])
    }

    // MARK: hit testing

    /// Deepest node whose frame contains `point` and that carries an action or tag.
    /// Frames are absolute, and children are searched back-to-front to match paint order.
    public func hitTest(_ point: CGPoint) -> LayoutNode? {
        guard frame.contains(point) || (frame.width == 0 && frame.height == 0) else { return nil }
        for child in children.reversed() {
            if let hit = child.hitTest(point) { return hit }
        }
        return (action != nil || tag != nil) ? self : nil
    }

    /// Every node whose placed frame contains `point`, in tree order. Diagnostics only: it answers
    /// "what is under the finger here?" when a tap seems to go nowhere, which is otherwise
    /// invisible without a debuggable build.
    public func path(containing point: CGPoint, depth: Int = 0, into result: inout [String]) {
        guard frame.contains(point) else { return }
        result.append(String(repeating: ".", count: min(depth, 12)) + portDescription)
        for child in children {
            child.path(containing: point, depth: depth + 1, into: &result)
        }
    }

    /// One-line description of this node for the demos' on-screen debug read-out.
    public var portDescription: String {
        let label: String
        switch kind {
        case .empty: label = "empty"
        case .text: label = "text"
        case let .stack(axis, _, _, _): label = axis == .vertical ? "vstack" : "hstack"
        case .zstack: label = "zstack"
        case .scroll: label = "scroll"
        case .spacer: label = "spacer"
        case .fill: label = "fill"
        case .shape: label = "shape"
        case .padding: label = "padding"
        case .frame: label = "frame"
        case .background: label = "background"
        case .overlay: label = "overlay"
        case .opacity: label = "opacity"
        case .offset: label = "offset"
        case .clip: label = "clip"
        case .shadow: label = "shadow"
        case .tap: label = "tap"
        case .group: label = "group"
        case .progressBar: label = "progressBar"
        case .sliderTrack: label = "sliderTrack"
        }
        let x = Int(frame.minX), y = Int(frame.minY)
        let w = Int(frame.width), h = Int(frame.height)
        return "\(label)[\(x),\(y) \(w)x\(h)] act=\(action != nil)"
    }

    /// All nodes carrying a tag, in paint order (used by list tests and debugging).
    public func taggedNodes() -> [LayoutNode] {
        var result: [LayoutNode] = []
        if tag != nil { result.append(self) }
        for child in children { result.append(contentsOf: child.taggedNodes()) }
        return result
    }

    @discardableResult
    public func onTap(_ body: @escaping () -> Void) -> LayoutNode {
        action = body
        return self
    }

    /// Attaches a continuous handler for controls that track the finger (sliders).
    @discardableResult
    public func onDrag(_ body: @escaping (CGPoint, CGRect) -> Void) -> LayoutNode {
        dragAction = body
        return self
    }

    /// The deepest node with a drag handler that contains `point` (controls win over scrolling).
    public func dragTarget(at point: CGPoint) -> LayoutNode? {
        guard frame.contains(point) else { return nil }
        for child in children.reversed() {
            if let hit = child.dragTarget(at: point) { return hit }
        }
        return dragAction != nil ? self : nil
    }

    @discardableResult
    public func tagged(_ value: Int) -> LayoutNode {
        tag = value
        return self
    }

    // MARK: convenience constructors

    public static func text(_ value: String,
                            style: TextStyleDescriptor,
                            lineLimit: Int? = nil,
                            alignment: CGFloat = 0) -> LayoutNode {
        LayoutNode(.text(TextSpec(text: value, style: style, lineLimit: lineLimit, alignment: alignment)))
    }

    public static func vstack(spacing: CGFloat = 8,
                              horizontalAlignment: CGFloat = 0.5,
                              verticalAlignment: CGFloat = 0.5,
                              _ children: [LayoutNode]) -> LayoutNode {
        LayoutNode(.stack(axis: .vertical, spacing: spacing,
                          horizontalAlignment: horizontalAlignment,
                          verticalAlignment: verticalAlignment), children: children)
    }

    public static func hstack(spacing: CGFloat = 8,
                              horizontalAlignment: CGFloat = 0.5,
                              verticalAlignment: CGFloat = 0.5,
                              _ children: [LayoutNode]) -> LayoutNode {
        LayoutNode(.stack(axis: .horizontal, spacing: spacing,
                          horizontalAlignment: horizontalAlignment,
                          verticalAlignment: verticalAlignment), children: children)
    }

    public static func zstack(horizontalAlignment: CGFloat = 0.5,
                              verticalAlignment: CGFloat = 0.5,
                              _ children: [LayoutNode]) -> LayoutNode {
        LayoutNode(.zstack(horizontalAlignment: horizontalAlignment,
                           verticalAlignment: verticalAlignment), children: children)
    }

    public static func scroll(offset: CGFloat = 0, _ content: LayoutNode) -> LayoutNode {
        LayoutNode(.scroll(offset: offset), content)
    }

    public static func spacer(minLength: CGFloat = 0) -> LayoutNode {
        LayoutNode(.spacer(minLength: minLength))
    }

    public static func color(_ color: RGBAColor) -> LayoutNode {
        LayoutNode(.fill(.color(color)))
    }

    public static func gradient(_ stops: [RGBAColor], start: CGPoint, end: CGPoint) -> LayoutNode {
        LayoutNode(.fill(.linearGradient(stops, start: start, end: end)))
    }

    public static func padding(_ insets: EdgeInsetsLike, _ child: LayoutNode) -> LayoutNode {
        LayoutNode(.padding(insets), child)
    }

    public static func padding(_ all: CGFloat, _ child: LayoutNode) -> LayoutNode {
        LayoutNode(.padding(EdgeInsetsLike(all)), child)
    }

    public static func frame(_ spec: FrameSpec, _ child: LayoutNode) -> LayoutNode {
        LayoutNode(.frame(spec), child)
    }

    public static func background(_ background: LayoutNode, _ content: LayoutNode) -> LayoutNode {
        LayoutNode(.background, children: [content, background])
    }

    public static func overlay(_ overlay: LayoutNode, _ content: LayoutNode) -> LayoutNode {
        LayoutNode(.overlay, children: [content, overlay])
    }

    // MARK: flexibility (drives stack distribution)

    /// A node is flexible along an axis when it can absorb leftover space (spacers, fills,
    /// shapes, and anything with a max constraint or an explicit frame).
    func isFlexible(along axis: StackAxis) -> Bool {
        let result: Bool
        switch kind {
        case .spacer, .fill:
            result = true
        case .progressBar, .sliderTrack:
            // Both stretch across the width they are offered, and stay at their natural height.
            result = axis == .horizontal
        case let .shape(kind, _, _):
            switch kind {
            case .circle, .capsule: result = false
            default: result = true
            }
        case let .frame(spec):
            // Only an *explicit* infinity makes a frame flexible along an axis. A `nil` maximum
            // means "no constraint" (natural size) — treating it as flexible made
            // `.frame(maxWidth: .infinity)` cards collapse to zero height inside a VStack.
            switch axis {
            case .horizontal: result = spec.maxWidth == .infinity
            case .vertical: result = spec.maxHeight == .infinity
            }
        case .padding:
            result = children.first?.isFlexible(along: axis) ?? false
        case let .stack(stackAxis, _, _, _):
            // Flexible along its *own* axis when a child is; across it the stack is content-sized.
            // A `Spacer()` inside an HStack makes the row flexible horizontally, not vertically —
            // treating it as flexible in both axes collapsed every highlight row to zero height.
            result = stackAxis == axis && children.contains { $0.isFlexible(along: axis) }
        case .background, .overlay, .tap, .clip, .shadow, .opacity, .offset:
            // Decorating wrappers follow their *content* (first child). The backdrop of a
            // `background`/`overlay` must not count: a flexible shape behind a pill would stretch
            // the pill instead of letting it hug its text.
            result = children.first?.isFlexible(along: axis) ?? false
        case .zstack, .scroll:
            result = children.contains { $0.isFlexible(along: axis) }
        case .group:
            result = children.contains { $0.isFlexible(along: axis) }
        default:
            result = false
        }
        return result
    }

    // MARK: - Measure

    /// Returns the size this node wants for the given proposal. `nil` dimensions in the
    /// proposal mean "choose your natural size".
    public func measure(_ proposal: ProposedSize) -> CGSize {
        switch kind {
        case .empty:
            return .zero

        case let .text(spec):
            let maxWidth = proposal.width
            let layout = textLayout(maxWidth: maxWidth, spec: spec)
            var width = layout.size.width
            var height = layout.size.height
            if let proposedWidth = proposal.width {
                width = min(width, max(0, proposedWidth))
            }
            if let proposedHeight = proposal.height {
                height = min(height, max(0, proposedHeight))
            }
            return CGSize(width: width, height: height)

        case let .stack(axis, spacing, _, _):
            return measureStack(axis: axis, spacing: spacing, proposal: proposal)

        case .scroll:
            // The viewport takes the proposal; the content decides its own height.
            let contentSize = children.first?.measure(ProposedSize(width: proposal.width, height: nil)) ?? .zero
            return CGSize(width: proposal.width ?? contentSize.width,
                          height: proposal.height ?? contentSize.height)

        case .zstack:
            var width: CGFloat = 0
            var height: CGFloat = 0
            for child in children {
                let size = child.measure(proposal)
                width = max(width, size.width)
                height = max(height, size.height)
            }
            return CGSize(width: proposal.width ?? width, height: proposal.height ?? height)

        case let .spacer(minLength):
            return CGSize(width: proposal.width ?? minLength,
                          height: proposal.height ?? minLength)

        case .fill(_):
            return CGSize(width: proposal.width ?? 10, height: proposal.height ?? 10)

        case .progressBar, .sliderTrack:
            let naturalHeight: CGFloat = {
                if case .progressBar = kind { return 5 }
                return 27
            }()
            return CGSize(width: proposal.width ?? 120, height: proposal.height ?? naturalHeight)

        case let .shape(shapeKind, _, _):
            if let width = proposal.width, let height = proposal.height {
                return CGSize(width: width, height: height)
            }
            if case let .circle = shapeKind, let side = proposal.width ?? proposal.height {
                return CGSize(width: side, height: side)
            }
            return CGSize(width: proposal.width ?? 10, height: proposal.height ?? 10)

        case let .padding(insets):
            let childProposal = ProposedSize(
                width: proposal.width.map { max(0, $0 - insets.leading - insets.trailing) },
                height: proposal.height.map { max(0, $0 - insets.top - insets.bottom) }
            )
            let childSize = children.first?.measure(childProposal) ?? .zero
            return CGSize(width: childSize.width + insets.leading + insets.trailing,
                          height: childSize.height + insets.top + insets.bottom)

        case let .frame(spec):
            return measureFrame(spec: spec, proposal: proposal)

        case .background, .overlay, .tap:
            return children.first?.measure(proposal) ?? .zero

        case let .opacity(alpha):
            _ = alpha
            return children.first?.measure(proposal) ?? .zero

        case .offset:
            // Offsetting moves the painted output; the reported size is unchanged.
            return children.first?.measure(proposal) ?? .zero

        case let .clip(radius):
            _ = radius
            return children.first?.measure(proposal) ?? .zero

        case .shadow:
            // A shadow is drawn outside the layout box, so it must not grow the box.
            return children.first?.measure(proposal) ?? .zero

        case .group:
            return children.reduce(CGSize.zero) { partial, child in
                let size = child.measure(proposal)
                return CGSize(width: max(partial.width, size.width), height: partial.height + size.height)
            }
        }
    }

    private func measureStack(axis: StackAxis, spacing: CGFloat, proposal: ProposedSize) -> CGSize {
        guard !children.isEmpty else { return .zero }

        let mainProposal: CGFloat?
        let crossProposal: CGFloat?
        switch axis {
        case .horizontal:
            mainProposal = proposal.width
            crossProposal = proposal.height
        case .vertical:
            mainProposal = proposal.height
            crossProposal = proposal.width
        }

        let totalSpacing = spacing * CGFloat(children.count - 1)
        let availableMain = mainProposal.map { max(0, $0 - totalSpacing) }

        // Fixed children are measured at their natural size; flexible ones share the rest.
        var sizes: [CGSize] = []
        var fixedTotal: CGFloat = 0
        var flexibleCount = 0
        for child in children {
            if child.isFlexible(along: axis) {
                flexibleCount += 1
                let crossSize = axis == .horizontal
                    ? child.measure(ProposedSize(width: nil, height: crossProposal))
                    : child.measure(ProposedSize(width: crossProposal, height: nil))
                sizes.append(axis == .horizontal
                             ? CGSize(width: 0, height: crossSize.height)
                             : CGSize(width: crossSize.width, height: 0))
            } else {
                let childProposal = axis == .horizontal
                    ? ProposedSize(width: nil, height: crossProposal)
                    : ProposedSize(width: crossProposal, height: nil)
                let size = child.measure(childProposal)
                sizes.append(size)
                fixedTotal += axis == .horizontal ? size.width : size.height
            }
        }

        var flexibleMain: CGFloat = 0
        if flexibleCount > 0, let availableMain {
            flexibleMain = max(0, availableMain - fixedTotal) / CGFloat(flexibleCount)
        }

        var mainTotal: CGFloat = 0
        var crossMax: CGFloat = 0
        for (index, child) in children.enumerated() {
            if child.isFlexible(along: axis) {
                let childProposal: ProposedSize = axis == .horizontal
                    ? ProposedSize(width: flexibleMain, height: crossProposal)
                    : ProposedSize(width: crossProposal, height: flexibleMain)
                let size = child.measure(childProposal)
                sizes[index] = size
                // A flexible child that answers smaller than its share still takes the share.
                let main = axis == .horizontal ? size.width : size.height
                mainTotal += max(main, flexibleMain)
                crossMax = max(crossMax, axis == .horizontal ? size.height : size.width)
            } else {
                let size = sizes[index]
                mainTotal += axis == .horizontal ? size.width : size.height
                crossMax = max(crossMax, axis == .horizontal ? size.height : size.width)
            }
        }

        mainTotal += totalSpacing
        if let mainProposal, flexibleCount > 0 {
            mainTotal = max(mainTotal, mainProposal)
        }

        switch axis {
        case .horizontal:
            return CGSize(width: mainTotal, height: crossMax)
        case .vertical:
            return CGSize(width: crossMax, height: mainTotal)
        }
    }

    private func measureFrame(spec: FrameSpec, proposal: ProposedSize) -> CGSize {
        let proposedWidth: CGFloat? = {
            if let maxWidth = spec.maxWidth, maxWidth.isFinite {
                if let proposed = proposal.width { return min(proposed, maxWidth) }
                return spec.idealWidth ?? maxWidth
            }
            if let ideal = spec.idealWidth { return ideal }
            return proposal.width
        }()
        let proposedHeight: CGFloat? = {
            if let maxHeight = spec.maxHeight, maxHeight.isFinite {
                if let proposed = proposal.height { return min(proposed, maxHeight) }
                return spec.idealHeight ?? maxHeight
            }
            if let ideal = spec.idealHeight { return ideal }
            return proposal.height
        }()

        let childSize = children.first?.measure(ProposedSize(width: proposedWidth, height: proposedHeight)) ?? .zero

        var width = frameLength(child: childSize.width, min: spec.minWidth, ideal: spec.idealWidth,
                                max: spec.maxWidth, proposal: proposal.width)
        var height = frameLength(child: childSize.height, min: spec.minHeight, ideal: spec.idealHeight,
                                 max: spec.maxHeight, proposal: proposal.height)

        if let explicit = spec.maxWidth, spec.minWidth == explicit, explicit.isFinite { width = explicit }
        if let explicit = spec.maxHeight, spec.minHeight == explicit, explicit.isFinite { height = explicit }

        return CGSize(width: max(0, width), height: max(0, height))
    }

    /// The length a frame reports along one axis.
    ///
    /// A frame *proposes* the parent's size to its child (so a child that wants to fill can), but
    /// it only *reports* the proposal when its own maximum is an explicit `.infinity`. With no
    /// maximum the frame wraps the child — reporting the proposal instead made
    /// `.frame(maxWidth: .infinity)` cards and tab bars as tall as the screen.
    private func frameLength(child: CGFloat, min lower: CGFloat?, ideal: CGFloat?,
                             max upper: CGFloat?, proposal: CGFloat?) -> CGFloat {
        var value = child
        if let ideal, ideal > value { value = ideal }
        if let upper {
            if upper.isFinite {
                value = Swift.min(value, upper)
            } else if let proposal {
                value = proposal
            }
        }
        if let lower { value = Swift.max(value, lower) }
        return value
    }

    private func segment(proposed: CGFloat?, min lower: CGFloat?, ideal: CGFloat?,
                         max upper: CGFloat?, childLength: CGFloat,
                         proposal: CGFloat?) -> CGFloat {
        var value: CGFloat
        if let proposed {
            value = proposed
        } else if let lower, let upper, lower == upper, lower.isFinite {
            value = lower
        } else if let ideal {
            value = ideal
        } else {
            value = childLength
        }
        if let lower { value = max(value, lower) }
        if let upper, upper.isFinite { value = min(value, upper) }
        return value
    }

    private func textLayout(maxWidth: CGFloat?, spec: TextSpec) -> TextLayout {
        if let cached = textLayoutCache, cached.width == maxWidth {
            return cached.layout
        }
        let layout = TextLayouter.layout(spec.text, style: spec.style, maxWidth: maxWidth, lineLimit: spec.lineLimit)
        textLayoutCache = (maxWidth, layout)
        return layout
    }

    /// Invalidates cached measurement. Called when style/text changes.
    public func invalidateMeasurement() {
        textLayoutCache = nil
        flexCache = nil
    }

    // MARK: - Place

    /// Assigns frames to this node and its descendants. `rect` is in the parent's space.
    public func place(in rect: CGRect) {
        frame = rect
        switch kind {
        case let .scroll(offset):
            let contentSize = children.first?.measure(ProposedSize(width: rect.width, height: nil)) ?? .zero
            children.first?.place(in: CGRect(x: rect.minX,
                                             y: rect.minY - offset,
                                             width: rect.width,
                                             height: contentSize.height))
        case let .zstack(horizontalAlignment, verticalAlignment):
            for child in children {
                let size = child.measure(ProposedSize(width: rect.width, height: rect.height))
                let origin = CGPoint(x: rect.minX + (rect.width - size.width) * horizontalAlignment,
                                     y: rect.minY + (rect.height - size.height) * verticalAlignment)
                child.place(in: CGRect(origin: origin, size: size))
            }
        case let .stack(axis, spacing, horizontalAlignment, verticalAlignment):
            placeStack(axis: axis, spacing: spacing,
                       horizontalAlignment: horizontalAlignment,
                       verticalAlignment: verticalAlignment, in: rect)
        case let .padding(insets):
            children.first?.place(in: rect.insetByEdgeInsets(insets))
        case let .frame(spec):
            guard let child = children.first else { break }
            let childSize = child.measure(ProposedSize(
                width: spec.maxWidth.flatMap { $0.isFinite ? $0 : nil } ?? rect.width,
                height: spec.maxHeight.flatMap { $0.isFinite ? $0 : nil } ?? rect.height
            ))
            var width = childSize.width
            var height = childSize.height
            if let explicit = spec.maxWidth, spec.minWidth == explicit, explicit.isFinite { width = explicit }
            if let explicit = spec.maxHeight, spec.minHeight == explicit, explicit.isFinite { height = explicit }
            // An explicitly infinite maximum fills the space it was given (that is what
            // `.frame(maxWidth: .infinity)` means), while its content stays centred inside.
            if spec.maxWidth == .infinity { width = rect.width }
            if spec.maxHeight == .infinity { height = rect.height }
            // The frame owns the box; the child keeps its natural size inside it and is positioned
            // by the frame's alignment. Placing the child at the frame's full size put an avatar's
            // initial in the top-left corner instead of its centre.
            let contentWidth = min(childSize.width, width)
            let contentHeight = min(childSize.height, height)
            let origin = CGPoint(
                x: rect.minX + (width - contentWidth) * spec.horizontalAlignment,
                y: rect.minY + (height - contentHeight) * spec.verticalAlignment
            )
            child.place(in: CGRect(origin: origin, size: CGSize(width: contentWidth, height: contentHeight)))
        case .background, .overlay:
            children.first?.place(in: rect)
            children.last?.place(in: rect)
        case .opacity, .clip, .shadow, .tap:
            children.first?.place(in: rect)
        case let .offset(x, y):
            children.first?.place(in: rect.translated(byX: -x, y: -y))
        case .group:
            var cursor = rect.minY
            for child in children {
                let size = child.measure(ProposedSize(width: rect.width, height: nil))
                child.place(in: CGRect(x: rect.minX, y: cursor, width: rect.width, height: size.height))
                cursor += size.height
            }
        default:
            break
        }
    }

    private func placeStack(axis: StackAxis, spacing: CGFloat,
                            horizontalAlignment: CGFloat, verticalAlignment: CGFloat,
                            in rect: CGRect) {
        let totalSpacing = spacing * CGFloat(max(0, children.count - 1))
        var fixedTotal: CGFloat = 0
        var flexibleCount = 0
        var measured: [CGSize] = []
        for child in children {
            if child.isFlexible(along: axis) {
                flexibleCount += 1
                measured.append(.zero)
            } else {
                let size = child.measure(axis == .horizontal
                    ? ProposedSize(width: nil, height: rect.height)
                    : ProposedSize(width: rect.width, height: nil))
                measured.append(size)
                fixedTotal += axis == .horizontal ? size.width : size.height
            }
        }

        let available = (axis == .horizontal ? rect.width : rect.height) - totalSpacing
        let flexibleShare = flexibleCount > 0 ? max(0, available - fixedTotal) / CGFloat(flexibleCount) : 0

        var cursor = axis == .horizontal ? rect.minX : rect.minY
        for (index, child) in children.enumerated() {
            let childFrame: CGRect
            if child.isFlexible(along: axis) {
                let main = flexibleShare
                switch axis {
                case .horizontal:
                    let height = rect.height
                    childFrame = CGRect(x: cursor, y: rect.minY, width: main, height: height)
                case .vertical:
                    let width = rect.width
                    childFrame = CGRect(x: rect.minX, y: cursor, width: width, height: main)
                }
                cursor += main
            } else {
                let size = measured[index]
                switch axis {
                case .horizontal:
                    let y = rect.minY + (rect.height - size.height) * verticalAlignment
                    childFrame = CGRect(x: cursor, y: y, width: size.width, height: size.height)
                    cursor += size.width
                case .vertical:
                    let x = rect.minX + (rect.width - size.width) * horizontalAlignment
                    childFrame = CGRect(x: x, y: cursor, width: size.width, height: size.height)
                    cursor += size.height
                }
            }
            child.place(in: childFrame)
            cursor += spacing
        }
    }

    // MARK: - Paint

    /// Appends draw commands in absolute coordinates.
    public func paint(into list: inout DisplayList) {
        switch kind {
        case .empty, .spacer:
            break

        case let .text(spec):
            let layout = textLayout(maxWidth: frame.width, spec: spec)
            for line in layout.lines {
                let origin = CGPoint(
                    x: frame.minX + (frame.width - line.width) * spec.alignment,
                    y: frame.minY + line.baselineY
                )
                list.append(.text(line.text, origin: origin, style: spec.style))
            }

        case .stack, .zstack:
            for child in children { child.paint(into: &list) }

        case .scroll:
            list.append(.save)
            list.append(.clip(frame, cornerRadius: 0))
            children.first?.paint(into: &list)
            list.append(.restore)

        case let .fill(style):
            switch style {
            case let .color(color):
                list.append(.fillRect(frame, color))
            case let .linearGradient(stops, start, end):
                let resolvedStart = CGPoint(x: frame.minX + start.x * frame.width,
                                            y: frame.minY + start.y * frame.height)
                let resolvedEnd = CGPoint(x: frame.minX + end.x * frame.width,
                                          y: frame.minY + end.y * frame.height)
                list.append(.linearGradient(frame, cornerRadius: 0,
                                            start: resolvedStart, end: resolvedEnd, stops: stops))
            }

        case let .progressBar(fraction, track, fillColor):
            let clamped = min(max(fraction, 0), 1)
            let radius = min(frame.height, frame.width) / 2
            list.append(.fillRoundRect(frame, cornerRadius: radius, track))
            if clamped > 0, frame.width > 0 {
                let filled = CGRect(x: frame.minX, y: frame.minY,
                                    width: frame.width * clamped, height: frame.height)
                list.append(.fillRoundRect(filled, cornerRadius: radius, fillColor))
            }

        case let .sliderTrack(fraction, track, fillColor, knob):
            // Geometry in one place: the drag handler maps a touch back through the same values.
            let geometry = PortSliderGeometry(frame: frame)
            let clamped = min(max(fraction, 0), 1)
            list.append(.fillRoundRect(geometry.trackRect, cornerRadius: geometry.trackHeight / 2, track))
            let filledWidth = geometry.trackRect.width * clamped
            if filledWidth > 0 {
                list.append(.fillRoundRect(CGRect(x: geometry.trackRect.minX,
                                                  y: geometry.trackRect.minY,
                                                  width: filledWidth,
                                                  height: geometry.trackHeight),
                                           cornerRadius: geometry.trackHeight / 2, fillColor))
            }
            let knobRect = geometry.knobRect(fraction: clamped)
            list.append(.shadowRoundRect(knobRect, cornerRadius: geometry.knobDiameter / 2,
                                         dx: 0, dy: 1, blur: 4,
                                         RGBAColor(hex: 0x000000, alpha: 0.28)))
            list.append(.fillOval(knobRect, knob))

        case let .shape(shapeKind, fill, stroke):
            let path: PathData
            let cornerRadius: CGFloat
            switch shapeKind {
            case .rectangle:
                cornerRadius = 0
                path = PathData.roundedRect(frame, cornerRadius: 0)
            case let .roundedRectangle(radius):
                cornerRadius = radius
                path = PathData.roundedRect(frame, cornerRadius: radius)
            case .circle, .capsule:
                cornerRadius = min(frame.width, frame.height) / 2
                path = PathData.roundedRect(frame, cornerRadius: cornerRadius)
            }
            if let fill {
                switch fill {
                case let .color(color):
                    list.append(.fillPath(path, color))
                case let .linearGradient(stops, start, end):
                    let resolvedStart = CGPoint(x: frame.minX + start.x * frame.width,
                                                y: frame.minY + start.y * frame.height)
                    let resolvedEnd = CGPoint(x: frame.minX + end.x * frame.width,
                                              y: frame.minY + end.y * frame.height)
                    // The gradient fill must honour the shape's corner radius, otherwise
                    // rounded cards and circular avatars paint as squares.
                    list.append(.linearGradient(frame, cornerRadius: cornerRadius,
                                                start: resolvedStart, end: resolvedEnd,
                                                stops: stops))
                }
            }
            if let stroke {
                list.append(.strokePath(path, width: stroke.width, stroke.color))
            }

        case let .padding(insets):
            _ = insets
            children.first?.paint(into: &list)

        case .frame:
            children.first?.paint(into: &list)

        case .background:
            let background = children.last
            let content = children.first
            if let background {
                var sub = DisplayList()
                background.paint(into: &sub)
                list.commands += sub.commands
            }
            content?.paint(into: &list)

        case .overlay:
            children.first?.paint(into: &list)
            children.last?.paint(into: &list)

        case let .opacity(alpha):
            list.append(.save)
            children.first?.paint(into: &list)
            list.append(.restore)
            _ = alpha   // per-command alpha is applied by the caller via color tints

        case let .offset(x, y):
            let original = frame
            frame = frame.translated(byX: x, y: y)
            children.first?.paint(into: &list)
            frame = original

        case let .clip(radius):
            list.append(.save)
            list.append(.clip(frame, cornerRadius: radius))
            children.first?.paint(into: &list)
            list.append(.restore)

        case let .shadow(dx, dy, blur, color, cornerRadius):
            list.append(.shadowRoundRect(frame, cornerRadius: cornerRadius, dx: dx, dy: dy, blur: blur, color))
            children.first?.paint(into: &list)

        case let .tap(action):
            _ = action
            children.first?.paint(into: &list)

        case .group:
            for child in children { child.paint(into: &list) }
        }
    }
}

// MARK: - Slider geometry

/// Where a slider's track, filled portion and knob are inside its placed frame.
///
/// Painting and hit-testing share this type: the drag handler maps the finger through
/// `fraction(atX:)`, the painter places the knob with `knobRect(fraction:)`, so the knob follows
/// the finger exactly instead of drifting near the ends.
public struct PortSliderGeometry {
    public let frame: CGRect

    public init(frame: CGRect) {
        self.frame = frame
    }

    /// The knob is as tall as the control (capped), which keeps it proportional at any text size.
    public var knobDiameter: CGFloat { min(26, max(frame.height, 1)) }
    public var trackHeight: CGFloat { 5 }

    /// The track stops half a knob from each edge, so the knob is never clipped by the control.
    public var trackRect: CGRect {
        let inset = knobDiameter / 2
        return CGRect(x: frame.minX + inset,
                      y: frame.midY - trackHeight / 2,
                      width: max(0, frame.width - knobDiameter),
                      height: trackHeight)
    }

    /// Fraction (0…1) for a touch at `x` in the node's coordinate space.
    public func fraction(atX x: CGFloat) -> CGFloat {
        let track = trackRect
        guard track.width > 0 else { return 0 }
        return min(max((x - track.minX) / track.width, 0), 1)
    }

    /// Knob box for a fraction, clamped so the knob stays inside the placement.
    public func knobRect(fraction: CGFloat) -> CGRect {
        let track = trackRect
        let clamped = min(max(fraction, 0), 1)
        return CGRect(x: track.minX + track.width * clamped - knobDiameter / 2,
                      y: frame.midY - knobDiameter / 2,
                      width: knobDiameter,
                      height: knobDiameter)
    }
}

// MARK: - Proposed size

/// The size a parent offers a child; `nil` means "choose your natural size".
public struct ProposedSize: Equatable {
    public var width: CGFloat?
    public var height: CGFloat?

    public init(width: CGFloat?, height: CGFloat?) {
        self.width = width
        self.height = height
    }

    public static let unspecified = ProposedSize(width: nil, height: nil)
    public static let zero = ProposedSize(width: 0, height: 0)
}

extension CGRect {
    func sContains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func translated(byX dx: CGFloat, y dy: CGFloat) -> CGRect {
        CGRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }

    func insetByEdgeInsets(_ insets: EdgeInsetsLike) -> CGRect {
        CGRect(x: minX + insets.leading,
               y: minY + insets.top,
               width: max(0, width - insets.leading - insets.trailing),
               height: max(0, height - insets.top - insets.bottom))
    }
}
