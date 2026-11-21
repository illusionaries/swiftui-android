// LayoutTests.swift — layout engine behaviour, pinned on the host.
//
// These are the port's contract tests: they encode SwiftUI's measure/place discipline
// (propose size → answer with own size → parent places child) without a device in the loop.
import XCTest
@testable import SwiftUI

final class LayoutTests: XCTestCase {
    private let body17 = TextStyleDescriptor(size: 17)

    /// Deterministic measurer so assertions are arithmetic, not font-dependent.
    private final class FixedMeasurer: SwiftUI.TextMeasurer {
        let advancePerGlyph: CGFloat
        init(advancePerGlyph: CGFloat) { self.advancePerGlyph = advancePerGlyph }

        func advance(_ text: String, style: TextStyleDescriptor) -> CGFloat {
            CGFloat(text.count) * advancePerGlyph
        }

        func metrics(style: TextStyleDescriptor) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
            (ascent: -0.8 * style.size, descent: 0.2 * style.size, leading: 0)
        }
    }

    override func setUp() {
        super.setUp()
        TextMeasurement.current = FixedMeasurer(advancePerGlyph: 10)
    }

    override func tearDown() {
        TextMeasurement.current = ApproximateTextMeasurer()
        super.tearDown()
    }

    // MARK: - Text

    func testTextNaturalSize() {
        let node = LayoutNode.text("abc", style: body17)
        let size = node.measure(.unspecified)
        XCTAssertEqual(size.width, 30, accuracy: 0.001)   // 3 glyphs × 10
        XCTAssertEqual(size.height, 17, accuracy: 0.001)  // ascent 13.6 + descent 3.4
    }

    func testTextWrapsToProposedWidth() {
        let node = LayoutNode.text("a b c d", style: body17)
        let size = node.measure(ProposedSize(width: 30, height: nil))
        XCTAssertLessThanOrEqual(size.width, 30.001)
        // "a b" = 30 wide fits; "c d" wraps → 2 lines.
        XCTAssertEqual(size.height, 34, accuracy: 0.001)
    }

    func testExplicitNewlinesArePreserved() {
        let node = LayoutNode.text("a\nb", style: body17)
        XCTAssertEqual(node.measure(.unspecified).height, 34, accuracy: 0.001)
    }

    func testSingleLineLimit() {
        let node = LayoutNode.text("a b c", style: body17, lineLimit: 1)
        let size = node.measure(ProposedSize(width: 10, height: nil))
        XCTAssertEqual(size.height, 17, accuracy: 0.001)
    }

    func testEmptyTextMeasuresZero() {
        XCTAssertEqual(LayoutNode.text("", style: body17).measure(.unspecified), .zero)
    }

    // MARK: - Stacks

    func testVStackSumsHeightsAndTakesMaxWidth() {
        let stack = LayoutNode.vstack(spacing: 8, [
            LayoutNode.text("aa", style: body17),      // 20 × 17
            LayoutNode.text("aaaaaaaa", style: body17) // 80 × 17
        ])
        let size = stack.measure(.unspecified)
        XCTAssertEqual(size.width, 80, accuracy: 0.001)
        XCTAssertEqual(size.height, 17 + 8 + 17, accuracy: 0.001)
    }

    func testHStackSumsWidthsAndTakesMaxHeight() {
        let stack = LayoutNode.hstack(spacing: 4, [
            LayoutNode.text("aa", style: body17),
            LayoutNode.text("aaaa", style: body17),
        ])
        let size = stack.measure(.unspecified)
        XCTAssertEqual(size.width, 20 + 4 + 40, accuracy: 0.001)
        XCTAssertEqual(size.height, 17, accuracy: 0.001)
    }

    func testSpacerAbsorbsRemainingWidth() {
        let stack = LayoutNode.hstack(spacing: 0, [
            LayoutNode.text("aa", style: body17),   // 20
            LayoutNode.spacer(),                    // flexible
            LayoutNode.text("aa", style: body17),   // 20
        ])
        let size = stack.measure(ProposedSize(width: 300, height: nil))
        XCTAssertEqual(size.width, 300, accuracy: 0.001)

        stack.place(in: CGRect(x: 0, y: 0, width: 300, height: 20))
        XCTAssertEqual(stack.children[0].frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(stack.children[2].frame.minX, 280, accuracy: 0.001)
        XCTAssertEqual(stack.children[1].frame.width, 260, accuracy: 0.001)
    }

    func testVStackPlacesChildrenTopToBottom() {
        let stack = LayoutNode.vstack(spacing: 6, [
            LayoutNode.text("a", style: body17),
            LayoutNode.text("b", style: body17),
        ])
        let size = stack.measure(.unspecified)
        stack.place(in: CGRect(origin: .zero, size: size))
        XCTAssertEqual(stack.children[0].frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(stack.children[1].frame.minY, 17 + 6, accuracy: 0.001)
    }

    func testZStackCentersChildren() {
        let stack = LayoutNode.zstack([
            LayoutNode.text("aaaa", style: body17),  // 40 × 17
            LayoutNode.text("a", style: body17),     // 10 × 17
        ])
        let size = stack.measure(.unspecified)
        XCTAssertEqual(size.width, 40, accuracy: 0.001)
        stack.place(in: CGRect(origin: .zero, size: size))
        XCTAssertEqual(stack.children[1].frame.minX, 15, accuracy: 0.001)
    }

    // MARK: - Modifier-shaped nodes

    func testPaddingGrowsMeasurementAndInsetsChild() {
        let node = LayoutNode.padding(EdgeInsetsLike(top: 4, bottom: 4, leading: 10, trailing: 10),
                                      .text("aa", style: body17))
        let size = node.measure(.unspecified)
        XCTAssertEqual(size.width, 40, accuracy: 0.001)
        XCTAssertEqual(size.height, 25, accuracy: 0.001)
        node.place(in: CGRect(origin: .zero, size: size))
        XCTAssertEqual(node.children[0].frame, CGRect(x: 10, y: 4, width: 20, height: 17))
    }

    func testFixedFrameOverridesChildSizeAndCentersIt() {
        // The frame owns the box; the child keeps its natural size and is centred inside it.
        // (This assertion used to require the child to fill the frame, which put an avatar's
        // initial in the corner instead of its centre.)
        let node = LayoutNode.frame(FrameSpec.width(100), .text("aa", style: body17))
        let size = node.measure(.unspecified)
        XCTAssertEqual(size.width, 100, accuracy: 0.001)
        node.place(in: CGRect(origin: .zero, size: size))
        XCTAssertEqual(node.children[0].frame.width, 20, accuracy: 0.001)
        XCTAssertEqual(node.children[0].frame.minX, 40, accuracy: 0.001)
    }

    func testFixedFrameCentresChildOnBothAxes() {
        // The avatar case: `.frame(width: 40, height: 40)` around a one-line text — the frame is
        // 40x40 and the glyphs are centred inside it.
        let spec = FrameSpec(minWidth: 40, idealWidth: 40, maxWidth: 40,
                             minHeight: 40, idealHeight: 40, maxHeight: 40)
        let node = LayoutNode.frame(spec, .text("L", style: body17))
        let size = node.measure(.unspecified)
        XCTAssertEqual(size, CGSize(width: 40, height: 40))
        node.place(in: CGRect(origin: .zero, size: size))
        let child = node.children[0].frame
        XCTAssertEqual(child.height, 17, accuracy: 0.001)
        XCTAssertEqual(child.minY, (40 - 17) / 2, accuracy: 0.001)
    }

    func testFrameMaxWidthClampsToProposal() {
        let node = LayoutNode.frame(FrameSpec(maxWidth: 50), .text("aaaaaaaaaa", style: body17))
        let size = node.measure(ProposedSize(width: 200, height: nil))
        XCTAssertEqual(size.width, 50, accuracy: 0.001)
    }

    func testBackgroundKeepsContentSize() {
        let content = LayoutNode.text("aa", style: body17)
        let node = LayoutNode.background(LayoutNode.color(.black), content)
        let size = node.measure(.unspecified)
        XCTAssertEqual(size.width, 20, accuracy: 0.001)
        XCTAssertEqual(size.height, 17, accuracy: 0.001)
    }

    func testBackgroundPaintsBeforeContent() {
        let node = LayoutNode.background(.color(.black), .text("a", style: body17))
        let size = node.measure(.unspecified)
        node.place(in: CGRect(origin: .zero, size: size))
        var list = DisplayList()
        node.paint(into: &list)
        guard case .fillRect = list.commands.first else {
            return XCTFail("background must be the first command, got \(String(describing: list.commands.first))")
        }
        guard case .text = list.commands.last else {
            return XCTFail("content text must paint after the background")
        }
    }

    func testOverlayPaintsAfterContent() {
        let node = LayoutNode.overlay(.color(.clear), .text("a", style: body17))
        let size = node.measure(.unspecified)
        node.place(in: CGRect(origin: .zero, size: size))
        var list = DisplayList()
        node.paint(into: &list)
        guard case .text = list.commands.first else {
            return XCTFail("content must paint first")
        }
    }

    // MARK: - Painting

    func testTextPaintProducesOneCommandPerLine() {
        let node = LayoutNode.text("a\nb\nc", style: body17)
        node.place(in: CGRect(origin: .zero, size: node.measure(.unspecified)))
        var list = DisplayList()
        node.paint(into: &list)
        XCTAssertEqual(list.commands.count, 3)
    }

    func testColorFillsProposal() {
        let node = LayoutNode.color(.white)
        XCTAssertEqual(node.measure(ProposedSize(width: 320, height: 480)),
                       CGSize(width: 320, height: 480))
        // Without a proposal a colour view falls back to a small default, like SwiftUI.
        XCTAssertEqual(node.measure(.unspecified), CGSize(width: 10, height: 10))
    }

    func testClipWrapsCommands() {
        let node = LayoutNode(.clip(cornerRadius: 8), .text("a", style: body17))
        let size = node.measure(.unspecified)
        node.place(in: CGRect(origin: .zero, size: size))
        var list = DisplayList()
        node.paint(into: &list)
        XCTAssertEqual(list.commands.first, .save)
        XCTAssertEqual(list.commands.last, .restore)
    }
}
