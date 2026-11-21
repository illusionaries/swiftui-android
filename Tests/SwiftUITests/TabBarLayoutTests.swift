import XCTest
@testable import SwiftUICore

/// The ported Atlas app's tab bar measured as tall as the whole screen, so its white background
/// covered the page. This reproduces the node chain the adapters build for
/// `HStack { item; item; item }.padding(.top, 10).padding(.bottom, 24)` and pins the geometry.
final class TabBarLayoutTests: XCTestCase {
    private let screen = ProposedSize(width: 411, height: 891)

    private func tabItem(_ title: String) -> LayoutNode {
        let dot = LayoutNode.frame(FrameSpec.width(12), LayoutNode(.shape(.circle, fill: nil, stroke: nil)))
        let label = LayoutNode.text(title, style: TextStyleDescriptor(
            size: 11, weight: .regular, color: RGBAColor(hex: 0x888888)))
        let column = LayoutNode(.stack(axis: .vertical, spacing: 5,
                                       horizontalAlignment: 0.5, verticalAlignment: 0.5),
                                children: [dot, label])
        return LayoutNode.frame(FrameSpec(minWidth: 10, idealWidth: nil, maxWidth: .infinity,
                                          minHeight: nil, idealHeight: nil, maxHeight: nil),
                                column)
    }

    private func tabBar() -> LayoutNode {
        let row = LayoutNode(.stack(axis: .horizontal, spacing: 8,
                                    horizontalAlignment: 0.5, verticalAlignment: 0.5),
                             children: [tabItem("Home"), tabItem("Discover"), tabItem("Profile")])
        let bottom = LayoutNode.padding(EdgeInsetsLike(top: 0, bottom: 24, leading: 0, trailing: 0), row)
        return LayoutNode.padding(EdgeInsetsLike(top: 10, bottom: 0, leading: 0, trailing: 0), bottom)
    }

    func testTabBarKeepsItsNaturalHeight() {
        let height = tabBar().measure(screen).height
        XCTAssertLessThan(height, 120, "a tab bar must not fill the screen; got \(height)")
        XCTAssertGreaterThan(height, 30, "a tab bar must fit its dot + label; got \(height)")
    }

    func testTabBarItemsDoNotExpandVertically() {
        let itemHeight = tabItem("Home").measure(ProposedSize(width: 137, height: 891)).height
        XCTAssertLessThan(itemHeight, 120, "maxWidth: .infinity must not make an item tall; got \(itemHeight)")
    }
}
