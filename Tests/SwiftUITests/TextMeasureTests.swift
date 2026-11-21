import XCTest
@testable import SwiftUI

/// Text wrapping inside containers has bitten the ported path twice: a caption that wrapped to
/// two lines at paint time while layout had measured one. These tests pin the measuring contract
/// the engine relies on (the approximate measurer is used on the host, the canvas measurer on
/// device — both must produce the same *decisions*).
final class TextMeasureTests: XCTestCase {
    private func measured(_ text: String, size: CGFloat, maxWidth: CGFloat) -> TextLayout {
        TextLayouter.layout(text,
                            style: TextStyleDescriptor(size: size, weight: .regular,
                                                      color: RGBAColor(hex: 0x000000)),
                            maxWidth: maxWidth)
    }

    func testLongCaptionWrapsToTwoLines() {
        let caption = "RoundedRectangle filled with a LinearGradient, clipped and shadowed"
        let wide = measured(caption, size: 12, maxWidth: 1000)
        let narrow = measured(caption, size: 12, maxWidth: 240)
        XCTAssertEqual(wide.lines.count, 1, "unbounded width must not wrap")
        XCTAssertGreaterThan(narrow.lines.count, 1, "narrow width must wrap")
        XCTAssertGreaterThan(narrow.size.height, wide.size.height,
                             "a wrapped block must be taller than a single line")
    }

    func testWrappedBlockHeightTracksLineCount() {
        let layout = measured("one two three four five six seven eight nine ten", size: 12, maxWidth: 120)
        let single = measured("one", size: 12, maxWidth: 1000)
        XCTAssertEqual(layout.size.height,
                       single.lineHeight * CGFloat(layout.lines.count),
                       accuracy: 0.001,
                       "block height must be lineHeight × lineCount")
    }

    // The adapter path (padding → frame → VStack → Text) needs the ported declarations, which the
    // host build does not include; it is exercised by scripts/ported-dev.sh on a device.
}
