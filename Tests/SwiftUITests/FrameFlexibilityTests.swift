import XCTest
@testable import SwiftUICore

/// A frame is flexible along an axis only when its maximum is *explicitly* infinite.
///
/// This pins a bug that broke the ported demo's layout: `.frame(maxWidth: .infinity)` cards were
/// treated as flexible in both axes, so a VStack handed them the leftover (zero) height while they
/// still painted their content — the cards overlapped the row above them.
final class FrameFlexibilityTests: XCTestCase {
    private func node(_ spec: FrameSpec) -> LayoutNode {
        LayoutNode.frame(spec, LayoutNode.text("card", style: TextStyleDescriptor(
            size: 17, weight: .regular, color: RGBAColor(hex: 0x000000))))
    }

    func testExplicitInfinityIsFlexible() {
        let spec = FrameSpec(maxWidth: .infinity)
        XCTAssertTrue(node(spec).isFlexible(along: .horizontal),
                      "maxWidth: .infinity must absorb horizontal space")
        XCTAssertFalse(node(spec).isFlexible(along: .vertical),
                       "maxWidth: .infinity must NOT make the node flexible vertically")
    }

    func testUnconstrainedAxisIsNotFlexible() {
        // maxHeight: nil means "no constraint" (natural size), not "fill the container".
        let spec = FrameSpec(maxWidth: .infinity, maxHeight: nil)
        XCTAssertFalse(node(spec).isFlexible(along: .vertical))
    }

    func testFixedFrameIsNotFlexible() {
        XCTAssertFalse(node(FrameSpec.width(44)).isFlexible(along: .horizontal))
        XCTAssertFalse(node(FrameSpec.height(44)).isFlexible(along: .vertical))
    }

    func testStacksPropagateFlexibilityFromChildren() {
        let flexible = LayoutNode(.stack(axis: .horizontal, spacing: 8,
                                         horizontalAlignment: 0, verticalAlignment: 0.5),
                                  children: [node(FrameSpec(maxWidth: .infinity))])
        XCTAssertTrue(flexible.isFlexible(along: .horizontal))
        XCTAssertFalse(flexible.isFlexible(along: .vertical))
    }
}
