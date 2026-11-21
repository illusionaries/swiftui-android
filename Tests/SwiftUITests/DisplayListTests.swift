// DisplayListTests.swift — host-side tests for the renderer-agnostic engine layer.
//
// These run on macOS (`swift test`) because `Sources/SwiftUI/Engine` deliberately contains no
// platform calls. They pin the wire formats the C bridge depends on.
import XCTest
@testable import SwiftUI

final class DisplayListTests: XCTestCase {
    func testColorArgbPacking() {
        XCTAssertEqual(RGBAColor(red: 1, green: 0, blue: 0).argb, 0xFFFF0000)
        XCTAssertEqual(RGBAColor(white: 1).argb, 0xFFFFFFFF)
        XCTAssertEqual(RGBAColor(red: 0, green: 0, blue: 0, alpha: 0).argb, 0x00000000)
        // Rounding must be symmetric: 0.5 → 128, not 127.
        XCTAssertEqual(RGBAColor(red: 0.5, green: 0.5, blue: 0.5).argb & 0xFF, 128)
    }

    func testColorClamping() {
        XCTAssertEqual(RGBAColor(red: 2, green: -1, blue: 0).argb, 0xFFFF0000)
        XCTAssertEqual(RGBAColor(white: 1, alpha: 2).argb >> 24, 0xFF)
    }

    func testAlphaScaling() {
        let color = RGBAColor(hex: 0x336699, alpha: 0.8)
        XCTAssertEqual(color.withAlpha(0.5).argb >> 24, 0x66)
    }

    func testPathEncodingMatchesCBridgeContract() {
        var path = PathData()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 0))
        path.closeSubpath()
        XCTAssertEqual(path.encoded(), [0, 0, 0, 1, 10, 0, 4])
    }

    func testPathQuadAndCubicEncoding() {
        var path = PathData()
        path.addQuad(control: CGPoint(x: 5, y: 5), to: CGPoint(x: 10, y: 0))
        path.addCubic(CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), to: CGPoint(x: 3, y: 3))
        XCTAssertEqual(path.encoded(), [2, 5, 5, 10, 0, 3, 1, 1, 2, 2, 3, 3])
    }

    func testRoundedRectDegeneratesToRectWhenRadiusZero() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let path = PathData.roundedRect(rect, cornerRadius: 0)
        XCTAssertEqual(path.elements.count, 5)   // 4 lines + close, no curves
    }

    func testRoundedRectClampsRadiusToHalfHeight() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        let path = PathData.roundedRect(rect, cornerRadius: 100)
        // Radius clamps to 10, so the curves never leave the rect.
        for element in path.elements {
            switch element {
            case let .move(point), let .line(point):
                XCTAssertTrue(rect.contains(point))
            case let .quad(control, point):
                XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(control))
                XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(point))
            case let .cubic(c1, c2, point):
                for p in [c1, c2, point] {
                    XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(p))
                }
            case .close:
                break
            }
        }
    }

    func testDisplayListAccumulatesInOrder() {
        var list = DisplayList()
        list.append(.save)
        list.append(.fillRect(CGRect(x: 0, y: 0, width: 1, height: 1), .black))
        list.append(.restore)
        XCTAssertEqual(list.commands.count, 3)
        XCTAssertEqual(list.commands.first, .save)
        XCTAssertEqual(list.commands.last, .restore)
    }
}
