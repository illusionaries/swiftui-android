// DemoScene.swift — proof-of-pipeline scene for the Android port.
//
// This draws with the port's DisplayList (the same list Apple's SwiftUI declarations will
// eventually feed). It exists to validate the whole chain on a device: Swift -> C bridge ->
// android.graphics.Canvas (Skia), including text metrics, touch, and the frame loop.
import Foundation
import SwiftUI

public final class DemoScene: PortScene {
    private var tapCount = 0
    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var isDark = false
    private var safeArea = EdgeInsetsLike.zero

    public init() {}

    public func update(_ context: SceneContext) {
        width = context.size.width
        height = context.size.height
        isDark = context.isDark
        safeArea = context.safeArea
    }

    public func handleTap(at point: CGPoint) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return false }
        tapCount += 1
        return true
    }

    public func draw(into list: inout DisplayList, context: SceneContext) {
        let background = isDark ? RGBAColor(hex: 0x0B0B0F) : RGBAColor(hex: 0xF5F5F7)
        list.append(.fillRect(CGRect(x: 0, y: 0, width: width, height: height), background))

        let inset = max(20, safeArea.top)
        var y = inset + 8

        // Title
        let title = TextStyleDescriptor(size: 34, weight: .bold, color: isDark ? .white : RGBAColor(hex: 0x111114))
        let titleMetrics = (ascent: CGFloat(-33), descent: CGFloat(8), leading: CGFloat(0))
        y += -titleMetrics.ascent
        list.append(.text("SwiftUI", origin: CGPoint(x: 24, y: y), style: title))
        y += titleMetrics.descent + 6

        list.append(.text("porting Apple's framework to Android",
                          origin: CGPoint(x: 24, y: y),
                          style: TextStyleDescriptor(size: 15, weight: .regular,
                                                     color: isDark ? RGBAColor(hex: 0x9A9AA2) : RGBAColor(hex: 0x6C6C74))))
        y += 36

        // Hero card with gradient
        let card = CGRect(x: 16, y: y, width: width - 32, height: 220)
        list.append(.shadowRoundRect(card, cornerRadius: 22, dx: 0, dy: 10, blur: 24,
                                     RGBAColor(hex: 0x000000, alpha: isDark ? 0.5 : 0.12)))
        list.append(.linearGradient(card, cornerRadius: 22,
                                    start: CGPoint(x: card.minX, y: card.minY),
                                    end: CGPoint(x: card.maxX, y: card.maxY),
                                    stops: [RGBAColor(hex: 0x5B7CFA), RGBAColor(hex: 0x9B5BFA), RGBAColor(hex: 0xF25BC0)]))
        list.append(.text("Native Swift", origin: CGPoint(x: card.minX + 24, y: card.minY + 56),
                          style: TextStyleDescriptor(size: 28, weight: .bold, color: .white)))
        list.append(.text("rendering through Skia Canvas via JNI",
                          origin: CGPoint(x: card.minX + 24, y: card.minY + 88),
                          style: TextStyleDescriptor(size: 14, weight: .medium,
                                                     color: RGBAColor(white: 1, alpha: 0.82))))
        // Pill row
        let pill = CGRect(x: card.minX + 24, y: card.minY + 120, width: 148, height: 36)
        list.append(.fillRoundRect(pill, cornerRadius: 18, RGBAColor(white: 1, alpha: 0.22)))
        list.append(.text("arm64 · API 35", origin: CGPoint(x: pill.minX + 16, y: pill.minY + 23),
                          style: TextStyleDescriptor(size: 13, weight: .semibold, color: .white)))

        y = card.maxY + 28

        // Interactive counter row
        let row = CGRect(x: 16, y: y, width: width - 32, height: 76)
        let rowFill = isDark ? RGBAColor(hex: 0x1C1C22) : RGBAColor(white: 1)
        list.append(.fillRoundRect(row, cornerRadius: 18, rowFill))
        list.append(.text("Taps", origin: CGPoint(x: row.minX + 20, y: row.minY + 30),
                          style: TextStyleDescriptor(size: 17, weight: .semibold,
                                                     color: isDark ? .white : RGBAColor(hex: 0x111114))))
        list.append(.text("\(tapCount)", origin: CGPoint(x: row.minX + 20, y: row.minY + 56),
                          style: TextStyleDescriptor(size: 15, weight: .regular,
                                                     color: isDark ? RGBAColor(hex: 0x9A9AA2) : RGBAColor(hex: 0x6C6C74))))
        // Chevron-ish circle
        let badge = CGRect(x: row.maxX - 64, y: row.minY + 20, width: 36, height: 36)
        list.append(.fillOval(badge, RGBAColor(hex: 0x0A84FF, alpha: 0.16)))
        list.append(.text("+", origin: CGPoint(x: badge.midX - 7, y: badge.midY + 7),
                          style: TextStyleDescriptor(size: 20, weight: .semibold, color: RGBAColor(hex: 0x0A84FF))))

        y = row.maxY + 24

        // Text scale ladder
        let ladder: [(String, CGFloat, TextStyleDescriptor.Weight)] = [
            ("Headline sample", 22, .semibold),
            ("Body text at 17pt with normal weight", 17, .regular),
            ("Footnote 13pt secondary", 13, .regular),
        ]
        for (index, item) in ladder.enumerated() {
            let color: RGBAColor = index == 2
                ? (isDark ? RGBAColor(hex: 0x8E8E93) : RGBAColor(hex: 0x7A7A80))
                : (isDark ? .white : RGBAColor(hex: 0x111114))
            list.append(.text(item.0, origin: CGPoint(x: 24, y: y + item.1),
                              style: TextStyleDescriptor(size: item.1, weight: item.2, color: color)))
            y += item.1 + 14
        }
    }
}

/// The runtime loads this symbol by name (dlsym) to discover the app's scene.
@_cdecl("swiftui_app_entry")
public func swiftuiAppEntry() -> UnsafeMutableRawPointer? {
    Unmanaged.passRetained(DemoScene() as AnyObject).toOpaque()
}
