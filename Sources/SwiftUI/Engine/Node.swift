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

    static func width(_ value: CGFloat) -> FrameSpec {
        FrameSpec(minWidth: value, idealWidth: value, maxWidth: value)
    }

    static func height(_ value: CGFloat) -> FrameSpec {
        FrameSpec(minHeight: value, idealHeight: value, maxHeight: value)
    }
}

public enum FillStyle: Equatable {
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
        case spacer(minLength: CGFloat)
        case fill(FillStyle)
        case shape(ShapeKind, fill: FillStyle?, stroke: (width: CGFloat, color: RGBAColor)?)
        case padding(EdgeInsetsLike)
        case frame(FrameSpec)
        /// children[0] = content, children[1] = background
        case background
        /// children[0] = content, children[1] = overlay
        case overlay
        case opacity(CGFloat)
        case offset(CGFloat, CGFloat)
        case clip(cornerRadius: CGFloat)
        case shadow(dx: CGFloat, dy: CGFloat, blur: CGFloat, color: RGBAColor)
        case tap(() -> Void)
        case group
    }

    public var kind: Kind
    public var children: [LayoutNode]
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
        LayoutNode(.stack(axis: .vertical, spacing: 0,
                          horizontalAlignment: horizontalAlignment,
                          verticalAlignment: verticalAlignment), children: children)
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
        case let .shape(kind, _, _):
            switch kind {
            case .circle, .capsule: result = false
            default: result = true
            }
        case let .frame(spec):
            switch axis {
            case .horizontal: result = spec.maxWidth == nil || spec.maxWidth == .infinity
            case .vertical: result = spec.maxHeight == nil || spec.maxHeight == .infinity
            }
        case .padding:
            result = children.first?.isFlexible(along: axis) ?? false
        case .background, .overlay, .tap:
            result = children.first?.isFlexible(along: axis) ?? false
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

        case let .spacer(minLength):
            return CGSize(width: proposal.width ?? minLength,
                          height: proposal.height ?? minLength)

        case .fill(_):
            return CGSize(width: proposal.width ?? 10, height: proposal.height ?? 10)

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

        case let .offset(x, y):
            let size = children.first?.measure(proposal) ?? .zero
            return CGSize(width: size.width + abs(x), height: size.height + abs(y))

        case let .clip(radius):
            _ = radius
            return children.first?.measure(proposal) ?? .zero

        case let .shadow(_, _, blur, _):
            let size = children.first?.measure(proposal) ?? .zero
            return CGSize(width: size.width + blur * 2, height: size.height + blur * 2)

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
                sizes.append(.zero)
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

        var width = segment(proposed: proposedWidth, min: spec.minWidth, ideal: spec.idealWidth,
                            max: spec.maxWidth, childLength: childSize.width, proposal: proposal.width)
        var height = segment(proposed: proposedHeight, min: spec.minHeight, ideal: spec.idealHeight,
                             max: spec.maxHeight, childLength: childSize.height, proposal: proposal.height)

        if let explicit = spec.maxWidth, spec.minWidth == explicit, explicit.isFinite { width = explicit }
        if let explicit = spec.maxHeight, spec.minHeight == explicit, explicit.isFinite { height = explicit }

        return CGSize(width: max(0, width), height: max(0, height))
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
            let origin = CGPoint(
                x: rect.minX + (rect.width - width) * spec.horizontalAlignment,
                y: rect.minY + (rect.height - height) * spec.verticalAlignment
            )
            child.place(in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
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

        case .stack:
            for child in children { child.paint(into: &list) }

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

        case let .shape(shapeKind, fill, stroke):
            let path: PathData
            switch shapeKind {
            case .rectangle:
                path = PathData.roundedRect(frame, cornerRadius: 0)
            case let .roundedRectangle(radius):
                path = PathData.roundedRect(frame, cornerRadius: radius)
            case .circle, .capsule:
                path = PathData.roundedRect(frame, cornerRadius: min(frame.width, frame.height) / 2)
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
                    list.append(.linearGradient(frame, cornerRadius: 0,
                                                start: resolvedStart, end: resolvedEnd, stops: stops))
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

        case let .shadow(dx, dy, blur, color):
            list.append(.shadowRoundRect(frame, cornerRadius: 0, dx: dx, dy: dy, blur: blur, color))
            children.first?.paint(into: &list)

        case let .tap(action):
            _ = action
            children.first?.paint(into: &list)

        case .group:
            for child in children { child.paint(into: &list) }
        }
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
