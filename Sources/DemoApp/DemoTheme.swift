// DemoTheme.swift — design tokens and data for the Atlas demo app.
//
// Nothing here is framework code: it is ordinary application styling expressed with the port's
// engine types (which the SwiftUI `View` adapters will later produce from `.padding`, `.font`,
// `Color`, `LinearGradient`, … exactly the same way).
import Foundation
import SwiftUI

// MARK: - Theme

struct Theme {
    let isDark: Bool

    var background: RGBAColor { isDark ? RGBAColor(hex: 0x0A0A0C) : RGBAColor(hex: 0xF4F4F7) }
    var surface: RGBAColor { isDark ? RGBAColor(hex: 0x17171B) : .white }
    var elevated: RGBAColor { isDark ? RGBAColor(hex: 0x212127) : RGBAColor(hex: 0xFFFFFF) }
    var ink: RGBAColor { isDark ? .white : RGBAColor(hex: 0x101014) }
    var inkSecondary: RGBAColor { isDark ? RGBAColor(hex: 0xA0A0AA) : RGBAColor(hex: 0x66666E) }
    var inkTertiary: RGBAColor { isDark ? RGBAColor(hex: 0x6E6E78) : RGBAColor(hex: 0x9A9AA2) }
    var accent: RGBAColor { RGBAColor(hex: 0x5B7CFA) }
    var accentSoft: RGBAColor { RGBAColor(hex: 0x5B7CFA, alpha: isDark ? 0.20 : 0.12) }
    var separator: RGBAColor { isDark ? RGBAColor(hex: 0x2C2C33) : RGBAColor(hex: 0xE6E6EC) }
    var shadow: RGBAColor { RGBAColor(hex: 0x000000, alpha: isDark ? 0.28 : 0.045) }

    var heroGradient: [RGBAColor] {
        [RGBAColor(hex: 0x5B7CFA), RGBAColor(hex: 0x8E5BFA), RGBAColor(hex: 0xF25BC0)]
    }

    var cardGradients: [[RGBAColor]] {
        [
            [RGBAColor(hex: 0x22D3EE), RGBAColor(hex: 0x3B82F6)],
            [RGBAColor(hex: 0xF472B6), RGBAColor(hex: 0xFB7185)],
            [RGBAColor(hex: 0x34D399), RGBAColor(hex: 0x10B981)],
            [RGBAColor(hex: 0xFBBF24), RGBAColor(hex: 0xF97316)],
            [RGBAColor(hex: 0xA78BFA), RGBAColor(hex: 0x6D28D9)],
            [RGBAColor(hex: 0x60A5FA), RGBAColor(hex: 0x2563EB)],
        ]
    }

    func label(_ size: CGFloat, _ weight: TextStyleDescriptor.Weight = .regular,
               color: RGBAColor? = nil) -> TextStyleDescriptor {
        TextStyleDescriptor(size: size, weight: weight, color: color ?? ink)
    }

    func mono(_ size: CGFloat, color: RGBAColor? = nil) -> TextStyleDescriptor {
        TextStyleDescriptor(size: size, weight: .medium, color: color ?? inkSecondary)
    }
}

// MARK: - Models

struct AtlasItem: Equatable {
    let id: Int
    let title: String
    let subtitle: String
    let category: String
    let blurb: String
    let highlights: [String]
    let minutes: Int
    let author: String
}

enum AtlasData {
    static let items: [AtlasItem] = [
        AtlasItem(
            id: 0,
            title: "Design tokens 2.0",
            subtitle: "Colour, type and spacing as data",
            category: "Systems",
            blurb: "Tokens move design decisions out of mockups and into code. This collection mirrors the palette and type ramp used across the Atlas app itself, so what you see here is what the renderer draws.",
            highlights: [
                "One source of truth for colour, radius and elevation",
                "Dark mode derived, never hand-tuned twice",
                "Type ramp on a 4 pt baseline grid",
            ],
            minutes: 6,
            author: "Nadia Okonkwo"
        ),
        AtlasItem(
            id: 1,
            title: "Layout without tears",
            subtitle: "Proposing sizes, not pixels",
            category: "Layout",
            blurb: "A parent proposes, a child answers, the parent places. Every screen in this app is composed from that one rule, which is also how the engine under it measures and positions everything.",
            highlights: [
                "Stacks distribute leftover space to flexible children",
                "Frames clamp, never fight, the proposal",
                "Text wraps against the width it is actually given",
            ],
            minutes: 8,
            author: "Ivo Martins"
        ),
        AtlasItem(
            id: 2,
            title: "Motion with intent",
            subtitle: "When to move, when to settle",
            category: "Motion",
            blurb: "Motion should explain a change of state, not decorate it. The rule of thumb used here: if an animation can be removed without losing information, it should be.",
            highlights: [
                "Enter and exit along the same path",
                "Durations scale with distance, not with taste",
                "Never animate two competing focal points",
            ],
            minutes: 5,
            author: "Sora Tanaka"
        ),
        AtlasItem(
            id: 3,
            title: "Type that breathes",
            subtitle: "Line height is a design decision",
            category: "Type",
            blurb: "Text is the interface. The ladder in this app goes from a 34 pt display down to an 11 pt caption, and the line heights are what make the small sizes still readable.",
            highlights: [
                "Body copy at 17 pt with generous leading",
                "Secondary text never below 60% contrast",
                "Optical sizing for display weights",
            ],
            minutes: 7,
            author: "Lena Fischer"
        ),
        AtlasItem(
            id: 4,
            title: "Colour on canvas",
            subtitle: "Gradients that stay tasteful",
            category: "Colour",
            blurb: "Two-stop gradients over a solid base, always with a shadow underneath to separate the card from the page. The palette is limited on purpose: six gradients, one accent.",
            highlights: [
                "Six gradients, all mid-tone safe",
                "Shadow carries depth, not colour",
                "Accent reserved for the primary action",
            ],
            minutes: 4,
            author: "Marek Nowak"
        ),
        AtlasItem(
            id: 5,
            title: "Shipping the port",
            subtitle: "What runs, what is next",
            category: "Engineering",
            blurb: "The app you are reading this in is Swift compiled for Android, drawing through the platform canvas. This card is a placeholder for the write-up of how the runtime underneath is put together.",
            highlights: [
                "Swift runtime, Android canvas",
                "Layout engine unit-tested on the host",
                "Declarations taken from Apple's interface",
            ],
            minutes: 9,
            author: "Port team"
        ),
    ]

    static let metrics: [(String, String)] = [
        ("128", "screens"),
        ("4.9", "rating"),
        ("12k", "users"),
        ("36", "components"),
    ]

    static let categories = ["All", "Systems", "Layout", "Motion", "Type"]
}
