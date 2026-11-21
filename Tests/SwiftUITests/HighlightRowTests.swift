import XCTest
@testable import SwiftUICore

/// The ported Detail screen renders each highlight as `HStack { dot; Text }.padding(.vertical, 2)`
/// inside a `VStack(spacing: 6)`; the rows overlapped on device, so this pins the row geometry.
final class HighlightRowTests: XCTestCase {
    private func row(_ text: String) -> LayoutNode {
        let dot = LayoutNode.frame(FrameSpec.width(6), LayoutNode(.shape(.circle, fill: nil, stroke: nil)))
        let label = LayoutNode.text(text, style: TextStyleDescriptor(
            size: 15, weight: .regular, color: RGBAColor(hex: 0x111114)))
        let hstack = LayoutNode(.stack(axis: .horizontal, spacing: 8,
                                       horizontalAlignment: 0, verticalAlignment: 0.5),
                                children: [dot, label])
        return LayoutNode.padding(EdgeInsetsLike(top: 2, bottom: 2, leading: 0, trailing: 0), hstack)
    }

    func testRowHeightCoversItsText() {
        let node = row("One source of truth")
        let measured = node.measure(ProposedSize(width: 411, height: nil))
        let textHeight = LayoutNode.text("One source of truth", style: TextStyleDescriptor(
            size: 15, weight: .regular, color: RGBAColor(hex: 0x111114)))
            .measure(ProposedSize(width: 411, height: nil)).height
        XCTAssertEqual(measured.height, textHeight + 4, accuracy: 0.5,
                       "a row must be its text height plus its vertical padding")
    }

    func testStackOfRowsDoesNotOverlap() {
        let rows = LayoutNode(.stack(axis: .vertical, spacing: 6, horizontalAlignment: 0, verticalAlignment: 0),
                              children: ["One source of truth", "Dark mode derived", "4 pt baseline grid"].map(row))
        let height = rows.measure(ProposedSize(width: 411, height: nil)).height
        let single = row("One source of truth").measure(ProposedSize(width: 411, height: nil)).height
        XCTAssertEqual(height, single * 3 + 12, accuracy: 0.5,
                       "three rows + two gaps must fit inside the stack's own height")
    }
}
