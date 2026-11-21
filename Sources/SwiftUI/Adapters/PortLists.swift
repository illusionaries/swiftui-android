// PortLists.swift — `ForEach` and `ScrollView`.
//
// `ForEach` exposes its data and content builder as public storage, so the engine can iterate it
// directly. `ScrollView` exposes its content; the scrolling itself is the engine's `.scroll` node
// plus a drag gesture, because Apple's scroll machinery lives in its binary.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// MARK: - ForEach

extension ForEach: _PortRenderable where Content: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        var nodes: [LayoutNode] = []
        for element in data {
            nodes.append(contentsOf: context.makeNodes(content(element), proposal: proposal))
        }
        return nodes
    }
}

// MARK: - Axis.Set

extension Axis.Set {
    public static var horizontal: Axis.Set { _optionSet(1 << Axis.horizontal.rawValue, as: Axis.Set.self) }
    public static var vertical: Axis.Set { _optionSet(1 << Axis.vertical.rawValue, as: Axis.Set.self) }
}

// MARK: - ScrollView

extension ScrollView {
    /// ScrollView's only storage is its content; scroll position is the engine's (see below).
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true,
                @ContentBuilder content: () -> Content) {
        self.content = content()
    }
}

/// Scroll offsets, kept outside the view tree for the same reason as state: the tree is rebuilt
/// every frame. One scroll view per slot, keyed by creation order.
public enum PortScrollStore {
    nonisolated(unsafe) private static var cursor = 0
    nonisolated(unsafe) private static var models: [Int: ScrollModel] = [:]

    public static func beginFrame() {
        cursor = 0
    }

    static func nextModel(contentHeight: CGFloat, viewportHeight: CGFloat) -> ScrollModel {
        let index = cursor
        cursor += 1
        var model = models[index] ?? ScrollModel()
        model.contentHeight = contentHeight
        model.viewportHeight = viewportHeight
        model.clamp()
        models[index] = model
        return model
    }

    /// Applies a drag to the scroll view that owns `point`, returning whether it consumed it.
    public static func apply(drag: PortDragGesture, at point: CGPoint) -> Bool {
        guard !models.isEmpty else { return false }
        // Single scroll view: the model with a positive scrollable range takes the gesture.
        for (index, model) in models.sorted(by: { $0.key < $1.key }) where model.maxOffset > 0 {
            var updated = model
            updated.offset = model.offset - drag.translation.y
            updated.clamp()
            models[index] = updated
            return true
        }
        return false
    }
}

extension ScrollView: _PortRenderable where Content: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let viewport = proposal.height ?? 0
        let content = context.makeNode(content, proposal: ProposedSize(width: proposal.width, height: nil))
        let contentHeight = content.measure(ProposedSize(width: proposal.width, height: nil)).height
        let model = PortScrollStore.nextModel(contentHeight: contentHeight, viewportHeight: viewport)
        return [LayoutNode.scroll(offset: model.offset, content)]
    }
}

// MARK: - LazyVGrid

extension LazyVGrid {
    /// The grid's columns/content are hidden by the interface (see port-impl/storage.txt), so the
    /// initialiser is supplied here.
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center,
                spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = .init(),
                @ContentBuilder content: () -> Content) {
        self._portColumns = columns
        self._portSpacing = spacing
        self._portContent = content()
    }
}

extension LazyVGrid: _PortRenderable where Content: View {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        guard let content = _portContent else { return [] }
        let columns = max(1, _portColumns.count)
        let spacing = _portSpacing ?? 8
        let available = proposal.width ?? 0
        let cellWidth = max(0, (available - spacing * CGFloat(columns - 1)) / CGFloat(columns))

        // The engine has no grid primitive; a grid is rows of equal-width frames, which is
        // exactly what a VStack of HStacks with fixed cell widths lays out.
        let items = context.makeNodes(content, proposal: ProposedSize(width: cellWidth, height: nil))
        var rows: [LayoutNode] = []
        var index = 0
        while index < items.count {
            let slice = Array(items[index ..< min(index + columns, items.count)])
            let cells = slice.map { item in
                LayoutNode.frame(FrameSpec.width(cellWidth), item)
            }
            let padded = cells.count == columns
                ? cells
                : cells + Array(repeating: LayoutNode(.empty), count: columns - cells.count)
            rows.append(LayoutNode(.stack(axis: .horizontal, spacing: spacing,
                                          horizontalAlignment: 0, verticalAlignment: 0),
                                   children: padded))
            index += columns
        }
        return [LayoutNode(.stack(axis: .vertical, spacing: spacing,
                                  horizontalAlignment: 0, verticalAlignment: 0),
                           children: rows)]
    }
}

// MARK: - Divider

extension Divider: _PortRenderable {
    nonisolated public func _portMakeNodes(proposal: ProposedSize, context: PortGraphContext) -> [LayoutNode] {
        let color = context.environment.isDark ? RGBAColor(hex: 0x3A3A3C) : RGBAColor(hex: 0xE5E5EA)
        return [LayoutNode.frame(FrameSpec.height(0.5), LayoutNode.color(color))]
    }
}
