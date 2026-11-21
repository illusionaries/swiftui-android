// AtlasScene.swift — the Atlas demo app: a multi-screen product UI built on the port.
//
// Structure mirrors what the SwiftUI adapters will produce:
//   state  →  tree of layout nodes  →  measure  →  place  →  display list  →  Android canvas
//
// Screens: Home (hero, cards, metrics, feed), Discover (search, chips, grid), Profile
// (header, stats, toggles), and a pushed Detail screen reachable from any card.
// Interaction: tab switching, push/pop navigation, scrolling, like/save, setting toggles.
import Foundation
import SwiftUI

public final class AtlasScene: PortScene {
    // MARK: - State

    enum Tab: Int, CaseIterable {
        case home, discover, profile

        var title: String {
            switch self {
            case .home: return "Home"
            case .discover: return "Discover"
            case .profile: return "Profile"
            }
        }
    }

    struct AppState: Equatable {
        var tab: Tab = .home
        var detail: Int?
        var liked: Set<Int> = [2]
        var saved: Set<Int> = []
        var toggles: Set<String> = ["notifications", "haptics"]
        var category: Int = 0
        var scrollOffset: CGFloat = 0
        /// Bumped whenever the layout should be rebuilt (state change).
        var revision: Int = 0
    }

    private var state = AppState()
    private var scroll = ScrollModel()
    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var isDark = false
    private var safeArea = EdgeInsetsLike.zero
    private var tree: LayoutNode?
    private var builtRevision = -1
    private var builtWidth: CGFloat = 0

    public init() {}

    private var theme: Theme { Theme(isDark: isDark) }
    private var tabBarHeight: CGFloat { 62 + safeArea.bottom }

    // MARK: - PortScene

    public func update(_ context: SceneContext) {
        let sizeChanged = context.size.width != width || context.size.height != height
        width = context.size.width
        height = context.size.height
        isDark = context.isDark
        safeArea = context.safeArea
        if sizeChanged { invalidateLayout() }
    }

    public func draw(into list: inout DisplayList, context: SceneContext) {
        list.append(.fillRect(CGRect(x: 0, y: 0, width: width, height: height), theme.background))
        let root = layoutTree()
        let proposal = ProposedSize(width: width, height: height)
        let size = root.measure(proposal)
        root.place(in: CGRect(x: 0, y: 0, width: width, height: max(size.height, height)))
        root.paint(into: &list)
    }

    public func handleTap(at point: CGPoint) -> Bool {
        guard let hit = layoutTree().hitTest(point) else { return false }
        if let action = hit.action {
            action()
            return true
        }
        return false
    }

    public func handleDrag(_ gesture: PortDragGesture) -> Bool {
        guard scroll.canScroll else { return false }
        if gesture.phase == .began { dragStartOffset = scroll.offset }
        // Content follows the finger: dragging up increases the offset.
        scroll.offset = dragStartOffset - (gesture.location.y - gesture.start.y)
        scroll.clamp()
        bump()
        return true
    }

    private var dragStartOffset: CGFloat = 0

    // MARK: - Scene plumbing

    private func bump() {
        state.revision += 1
    }

    private func invalidateLayout() {
        tree = nil
        builtRevision = -1
    }

    private func select(tab: Tab) {
        guard state.tab != tab || state.detail != nil else { return }
        state.tab = tab
        state.detail = nil
        scroll = ScrollModel()
        dragStartOffset = 0
        invalidateLayout()
        bump()
    }

    private func openDetail(_ id: Int) {
        state.detail = id
        scroll = ScrollModel()
        dragStartOffset = 0
        invalidateLayout()
        bump()
    }

    private func closeDetail() {
        state.detail = nil
        invalidateLayout()
        bump()
    }

    private func toggle(_ key: String) {
        if state.toggles.contains(key) { state.toggles.remove(key) } else { state.toggles.insert(key) }
        bump()
    }

    private func toggleLike(_ id: Int) {
        if state.liked.contains(id) { state.liked.remove(id) } else { state.liked.insert(id) }
        bump()
    }

    private func toggleSave(_ id: Int) {
        if state.saved.contains(id) { state.saved.remove(id) } else { state.saved.insert(id) }
        bump()
    }

    // MARK: - Layout entry

    private func layoutTree() -> LayoutNode {
        if let tree, builtRevision == state.revision, builtWidth == width { return tree }
        let root = build()
        tree = root
        builtRevision = state.revision
        builtWidth = width
        return root
    }

    private func build() -> LayoutNode {
        let content: LayoutNode
        if let id = state.detail, let item = AtlasData.items.first(where: { $0.id == id }) {
            content = detailScreen(item)
        } else {
            switch state.tab {
            case .home: content = homeScreen()
            case .discover: content = discoverScreen()
            case .profile: content = profileScreen()
            }
        }

        let viewportHeight = height - tabBarHeight
        let contentHeight = content.measure(ProposedSize(width: width, height: nil)).height
        scroll.contentHeight = contentHeight
        scroll.viewportHeight = viewportHeight
        scroll.clamp()

        let scroller = LayoutNode(.scroll(offset: scroll.offset), content)
            .frame(FrameSpec(minHeight: viewportHeight, maxHeight: viewportHeight))

        let root = LayoutNode.zstack(horizontalAlignment: 0.5, verticalAlignment: 1, [scroller, tabBar()])
        return root.frame(FrameSpec(minHeight: height, maxHeight: height))
    }

    // MARK: - Shared components

    private func hpad(_ child: LayoutNode, extra: CGFloat = 0) -> LayoutNode {
        child.padding(EdgeInsetsLike(top: 0, bottom: 0, leading: 20 + extra, trailing: 20 + extra))
    }

    private func sectionHeader(_ title: String, trailing: String? = nil, onTrailing: (() -> Void)? = nil) -> LayoutNode {
        var row: [LayoutNode] = [
            LayoutNode.text(title, style: theme.label(19, .semibold)),
        ]
        row.append(LayoutNode.spacer())
        if let trailing {
            var label = LayoutNode.text(trailing, style: theme.label(13, .semibold, color: theme.accent))
            if let onTrailing { label = label.onTap(onTrailing) }
            row.append(label)
        }
        return LayoutNode.hstack(spacing: 8, verticalAlignment: 0.5, row)
    }

    private func pill(_ text: String, fill: RGBAColor, textColor: RGBAColor) -> LayoutNode {
        LayoutNode.text(text, style: TextStyleDescriptor(size: 11, weight: .semibold, color: textColor))
            .padding(EdgeInsetsLike(top: 5, bottom: 5, leading: 10, trailing: 10))
            .surfaceFill(.color(fill), radius: 11)
    }

    private func badge(_ glyph: String, fill: RGBAColor, tint: RGBAColor, size: CGFloat = 40) -> LayoutNode {
        LayoutNode.text(glyph, style: TextStyleDescriptor(size: size * 0.42, weight: .bold, color: tint),
                        alignment: 0.5)
            .height(size)
            .width(size)
            .surfaceFill(.color(fill), radius: size / 2)
    }

    private func header(_ title: String, subtitle: String) -> LayoutNode {
        LayoutNode.vstack(spacing: 3, horizontalAlignment: 0, [
            LayoutNode.text(title, style: theme.label(30, .bold)),
            LayoutNode.text(subtitle, style: theme.label(13, color: theme.inkSecondary)),
        ])
    }

    // MARK: - Home

    private func homeScreen() -> LayoutNode {
        let heroItem = AtlasData.items[0]
        var sections: [LayoutNode] = []

        // App header row
        let avatar = LayoutNode.text("AT", style: TextStyleDescriptor(size: 12, weight: .bold, color: .white),
                                     alignment: 0.5)
            .frame(FrameSpec(minWidth: 38, idealWidth: 38, maxWidth: 38,
                             minHeight: 38, idealHeight: 38, maxHeight: 38))
            .surfaceFill(.linearGradient(theme.heroGradient,
                                         start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)), radius: 19)
            .onTap { [weak self] in self?.select(tab: .profile) }
        let topRow = LayoutNode.hstack(spacing: 12, verticalAlignment: 0.5, [
            LayoutNode.vstack(spacing: 3, horizontalAlignment: 0, [
                LayoutNode.text("Atlas", style: theme.label(30, .bold)),
                LayoutNode.text("Curated design reading", style: theme.label(13, color: theme.inkSecondary)),
            ]),
            LayoutNode.spacer(),
            avatar,
        ])
        sections.append(hpad(topRow))

        // Hero card
        let heroText = LayoutNode.vstack(spacing: 8, horizontalAlignment: 0, [
            pill(heroItem.category.uppercased(), fill: RGBAColor(white: 1, alpha: 0.22), textColor: .white),
            LayoutNode.text(heroItem.title, style: TextStyleDescriptor(size: 27, weight: .bold, color: .white)),
            LayoutNode.text(heroItem.subtitle,
                            style: TextStyleDescriptor(size: 14, weight: .medium, color: RGBAColor(white: 1, alpha: 0.85))),
            LayoutNode.spacer(minLength: 8),
            LayoutNode.hstack(spacing: 8, verticalAlignment: 0.5, [
                LayoutNode.text("Read · \(heroItem.minutes) min",
                                style: TextStyleDescriptor(size: 13, weight: .semibold, color: .white)),
                LayoutNode.spacer(),
                LayoutNode.text("→", style: TextStyleDescriptor(size: 18, weight: .bold, color: .white)),
            ]),
        ])
        let hero = heroText
            .padding(EdgeInsetsLike(top: 22, bottom: 20, leading: 22, trailing: 22))
            .height(212)
            .surfaceFill(.linearGradient(theme.heroGradient,
                                         start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)), radius: 24)
            .shadow(dy: 10, blur: 22, color: theme.shadow, cornerRadius: 24)
            .onTap { [weak self] in self?.openDetail(heroItem.id) }
        sections.append(hpad(hero))

        // Continue reading — two compact cards
        sections.append(hpad(sectionHeader("Continue reading", trailing: "See all") { [weak self] in
            self?.select(tab: .discover)
        }))
        let pair = AtlasData.items[1...2].map { compactCard($0) }
        sections.append(hpad(LayoutNode.hstack(spacing: 12, verticalAlignment: 0, Array(pair))))

        // Metrics
        sections.append(hpad(sectionHeader("This month")))
        var tiles: [LayoutNode] = []
        for index in stride(from: 0, to: AtlasData.metrics.count, by: 2) {
            let left = metricTile(AtlasData.metrics[index].0, AtlasData.metrics[index].1)
            let right = metricTile(AtlasData.metrics[index + 1].0, AtlasData.metrics[index + 1].1)
            tiles.append(LayoutNode.hstack(spacing: 12, verticalAlignment: 0.5, [left, right]))
        }
        sections.append(hpad(LayoutNode.vstack(spacing: 12, horizontalAlignment: 0, tiles)))

        // Feed
        sections.append(hpad(sectionHeader("Latest")))
        var rows: [LayoutNode] = []
        for item in AtlasData.items[1...4] {
            rows.append(feedRow(item))
        }
        sections.append(hpad(LayoutNode.vstack(spacing: 10, horizontalAlignment: 0, rows)))

        sections.append(LayoutNode.spacer(minLength: 24))

        return LayoutNode.vstack(spacing: 16, horizontalAlignment: 0, sections)
            .padding(EdgeInsetsLike(top: max(safeArea.top, 16) + 6, bottom: 0, leading: 0, trailing: 0))
    }

    private func compactCard(_ item: AtlasItem) -> LayoutNode {
        let thumb = LayoutNode(.shape(.roundedRectangle(cornerRadius: 14),
                                      fill: .linearGradient(theme.cardGradients[item.id % theme.cardGradients.count],
                                                            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)),
                                      stroke: nil))
            .height(78)
        return LayoutNode.vstack(spacing: 8, horizontalAlignment: 0, [
            thumb,
            LayoutNode.text(item.title, style: theme.label(14, .semibold), lineLimit: 1),
            LayoutNode.text(item.subtitle, style: theme.label(11, color: theme.inkSecondary), lineLimit: 2),
        ])
        .onTap { [weak self] in self?.openDetail(item.id) }
    }

    private func metricTile(_ value: String, _ caption: String) -> LayoutNode {
        LayoutNode.vstack(spacing: 3, horizontalAlignment: 0, [
            LayoutNode.text(value, style: theme.label(24, .bold)),
            LayoutNode.text(caption, style: theme.label(12, color: theme.inkSecondary)),
        ])
        .padding(EdgeInsetsLike(top: 14, bottom: 14, leading: 16, trailing: 16))
        .surfaceFill(.color(theme.surface), radius: 16)
    }

    private func feedRow(_ item: AtlasItem) -> LayoutNode {
        let gradient = theme.cardGradients[item.id % theme.cardGradients.count]
        let icon = badge(String(item.title.prefix(1)), fill: RGBAColor.clear, tint: .white, size: 40)
            .background(LayoutNode(.shape(.roundedRectangle(cornerRadius: 12),
                                         fill: .linearGradient(gradient,
                                                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)),
                                         stroke: nil)))
        let text = LayoutNode.vstack(spacing: 3, horizontalAlignment: 0, [
            LayoutNode.text(item.title, style: theme.label(15, .semibold), lineLimit: 1),
            LayoutNode.text(item.subtitle, style: theme.label(12, color: theme.inkSecondary), lineLimit: 1),
        ])
        let row = LayoutNode.hstack(spacing: 12, verticalAlignment: 0.5, [
            icon,
            text,
            LayoutNode.spacer(),
            LayoutNode.text("›", style: theme.label(18, .semibold, color: theme.inkTertiary)),
        ])
        .padding(EdgeInsetsLike(top: 12, bottom: 12, leading: 12, trailing: 14))
        .surfaceFill(.color(theme.surface), radius: 16)
        return row.onTap { [weak self] in self?.openDetail(item.id) }
    }

    // MARK: - Discover

    private func discoverScreen() -> LayoutNode {
        var sections: [LayoutNode] = []
        sections.append(hpad(header("Discover", subtitle: "\(AtlasData.items.count) collections · updated today")))

        let search = LayoutNode.hstack(spacing: 10, verticalAlignment: 0.5, [
            LayoutNode(.shape(.circle, fill: .color(theme.inkTertiary), stroke: nil)).height(14).width(14),
            LayoutNode.text("Search components", style: theme.label(14, color: theme.inkTertiary)),
            LayoutNode.spacer(),
        ])
        .padding(EdgeInsetsLike(top: 12, bottom: 12, leading: 14, trailing: 14))
        .surfaceFill(.color(theme.surface), radius: 14)
        sections.append(hpad(search))

        var chips: [LayoutNode] = []
        for (index, category) in AtlasData.categories.enumerated() {
            let selected = state.category == index
            let chip = LayoutNode.text(category, style: theme.label(13, .semibold,
                                                                    color: selected ? .white : theme.inkSecondary))
                .padding(EdgeInsetsLike(top: 8, bottom: 8, leading: 14, trailing: 14))
                .surfaceFill(.color(selected ? theme.accent : theme.surface), radius: 16)
                .onTap { [weak self] in
                    self?.state.category = index
                    self?.bump()
                }
            chips.append(chip)
        }
        sections.append(hpad(LayoutNode.hstack(spacing: 8, verticalAlignment: 0.5, chips)))

        // Two-column grid of cards
        let items = AtlasData.items
        var rows: [LayoutNode] = []
        var index = 0
        while index < items.count {
            let left = gridCard(items[index])
            let right = index + 1 < items.count ? gridCard(items[index + 1]) : LayoutNode.spacer(minLength: 0)
            rows.append(LayoutNode.hstack(spacing: 12, verticalAlignment: 0, [left, right]))
            index += 2
        }
        sections.append(hpad(LayoutNode.vstack(spacing: 12, horizontalAlignment: 0, rows)))
        sections.append(LayoutNode.spacer(minLength: 24))

        return LayoutNode.vstack(spacing: 16, horizontalAlignment: 0, sections)
            .padding(EdgeInsetsLike(top: max(safeArea.top, 16) + 6, bottom: 0, leading: 0, trailing: 0))
    }

    private func gridCard(_ item: AtlasItem) -> LayoutNode {
        let gradient = theme.cardGradients[item.id % theme.cardGradients.count]
        let thumb = LayoutNode(.shape(.roundedRectangle(cornerRadius: 14),
                                      fill: .linearGradient(gradient,
                                                            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)),
                                      stroke: nil))
            .height(96)
            .overlay(
                LayoutNode.text(item.category.uppercased(),
                                style: TextStyleDescriptor(size: 10, weight: .bold, color: .white))
                    .padding(EdgeInsetsLike(top: 4, bottom: 4, leading: 8, trailing: 8))
                    .surfaceFill(.color(RGBAColor(white: 0, alpha: 0.22)), radius: 9)
                    .padding(8)
            )
        let saved = state.saved.contains(item.id)
        return LayoutNode.vstack(spacing: 8, horizontalAlignment: 0, [
            thumb,
            LayoutNode.text(item.title, style: theme.label(15, .semibold), lineLimit: 1),
            LayoutNode.text(item.subtitle, style: theme.label(12, color: theme.inkSecondary), lineLimit: 2),
            LayoutNode.hstack(spacing: 6, verticalAlignment: 0.5, [
                pill("\(item.minutes) min", fill: theme.accentSoft, textColor: theme.accent),
                LayoutNode.spacer(),
                LayoutNode.text(saved ? "★" : "☆",
                                style: theme.label(15, .semibold, color: saved ? theme.accent : theme.inkTertiary)),
            ]),
        ])
        .onTap { [weak self] in self?.openDetail(item.id) }
    }

    // MARK: - Profile

    private func profileScreen() -> LayoutNode {
        var sections: [LayoutNode] = []

        let avatar = LayoutNode.text("AT", style: TextStyleDescriptor(size: 26, weight: .bold, color: .white),
                                     alignment: 0.5)
            .frame(FrameSpec(minWidth: 76, idealWidth: 76, maxWidth: 76,
                             minHeight: 76, idealHeight: 76, maxHeight: 76))
            .surfaceFill(.linearGradient(theme.heroGradient,
                                         start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)), radius: 38)
            .shadow(dy: 8, blur: 18, color: theme.shadow, cornerRadius: 38)
        sections.append(hpad(LayoutNode.hstack(spacing: 16, verticalAlignment: 0.5, [
            avatar,
            LayoutNode.vstack(spacing: 4, horizontalAlignment: 0, [
                LayoutNode.text("Atlas Member", style: theme.label(22, .bold)),
                LayoutNode.text("@atlas · design systems", style: theme.label(13, color: theme.inkSecondary)),
                pill("Pro", fill: theme.accentSoft, textColor: theme.accent),
            ]),
            LayoutNode.spacer(),
        ])))

        let stats = LayoutNode.hstack(spacing: 10, verticalAlignment: 0.5, [
            metricTile("42", "Saved"),
            metricTile("18", "Likes"),
            metricTile("7", "Streak"),
        ])
        sections.append(hpad(stats))

        sections.append(hpad(sectionHeader("Preferences")))
        var settingRows: [LayoutNode] = []
        let settings: [(key: String, title: String, subtitle: String)] = [
            ("notifications", "Notifications", "New collections and replies"),
            ("haptics", "Haptics", "Subtle feedback on taps"),
            ("compact", "Compact rows", "Denser feed layout"),
        ]
        for setting in settings {
            settingRows.append(settingsRow(key: setting.key, title: setting.title, subtitle: setting.subtitle))
        }
        sections.append(hpad(LayoutNode.vstack(spacing: 10, horizontalAlignment: 0, settingRows)))

        sections.append(hpad(sectionHeader("About")))
        let about = LayoutNode.text(
            "Atlas is a demo application running on the SwiftUI port: Swift compiled for Android, laid out by this engine and drawn through the platform canvas.",
            style: theme.label(13, color: theme.inkSecondary))
            .padding(EdgeInsetsLike(top: 14, bottom: 14, leading: 16, trailing: 16))
            .surfaceFill(.color(theme.surface), radius: 16)
        sections.append(hpad(about))

        let reset = LayoutNode.text("Reset demo state",
                                    style: theme.label(14, .semibold, color: theme.accent), alignment: 0.5)
            .height(46)
            .surfaceFill(.color(theme.accentSoft), radius: 14)
            .onTap { [weak self] in
                guard let self else { return }
                self.state = AppState()
                self.scroll = ScrollModel()
                self.invalidateLayout()
            }
        sections.append(hpad(reset))
        sections.append(LayoutNode.spacer(minLength: 24))

        return LayoutNode.vstack(spacing: 16, horizontalAlignment: 0, sections)
            .padding(EdgeInsetsLike(top: max(safeArea.top, 16) + 6, bottom: 0, leading: 0, trailing: 0))
    }

    private func settingsRow(key: String, title: String, subtitle: String) -> LayoutNode {
        let isOn = state.toggles.contains(key)
        let trackWidth: CGFloat = 46
        let knob = LayoutNode(.shape(.circle, fill: .color(.white), stroke: nil)).height(20).width(20)
        let track = LayoutNode.zstack(horizontalAlignment: isOn ? 1 : 0, verticalAlignment: 0.5, [knob])
            .height(26)
            .width(trackWidth)
            .surfaceFill(.color(isOn ? theme.accent : theme.separator), radius: 13)
            .padding(3)
        let row = LayoutNode.hstack(spacing: 12, verticalAlignment: 0.5, [
            LayoutNode.vstack(spacing: 2, horizontalAlignment: 0, [
                LayoutNode.text(title, style: theme.label(15, .semibold)),
                LayoutNode.text(subtitle, style: theme.label(12, color: theme.inkSecondary)),
            ]),
            LayoutNode.spacer(),
            track,
        ])
        .padding(EdgeInsetsLike(top: 12, bottom: 12, leading: 16, trailing: 14))
        .surfaceFill(.color(theme.surface), radius: 16)
        return row.onTap { [weak self] in self?.toggle(key) }
    }

    // MARK: - Detail

    private func detailScreen(_ item: AtlasItem) -> LayoutNode {
        let gradient = theme.cardGradients[item.id % theme.cardGradients.count]
        var sections: [LayoutNode] = []

        let back = LayoutNode.hstack(spacing: 6, verticalAlignment: 0.5, [
            LayoutNode.text("‹", style: theme.label(22, .semibold, color: theme.accent)),
            LayoutNode.text("Back", style: theme.label(15, .semibold, color: theme.accent)),
        ])
        .padding(EdgeInsetsLike(top: 6, bottom: 6, leading: 10, trailing: 14))
        .onTap { [weak self] in self?.closeDetail() }
        sections.append(hpad(LayoutNode.hstack(spacing: 8, verticalAlignment: 0.5, [back, LayoutNode.spacer()])))

        let heroHeader = LayoutNode.vstack(spacing: 8, horizontalAlignment: 0, [
            pill(item.category.uppercased(), fill: RGBAColor(white: 1, alpha: 0.22), textColor: .white),
            LayoutNode.text(item.title, style: TextStyleDescriptor(size: 28, weight: .bold, color: .white)),
            LayoutNode.text(item.subtitle,
                            style: TextStyleDescriptor(size: 14, weight: .medium, color: RGBAColor(white: 1, alpha: 0.88))),
            LayoutNode.spacer(minLength: 6),
            LayoutNode.text("\(item.author) · \(item.minutes) min read",
                            style: TextStyleDescriptor(size: 12, weight: .medium, color: RGBAColor(white: 1, alpha: 0.75))),
        ])
        .padding(EdgeInsetsLike(top: 20, bottom: 18, leading: 20, trailing: 20))
        .height(196)
        .surfaceFill(.linearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)), radius: 22)
        .shadow(dy: 10, blur: 20, color: theme.shadow, cornerRadius: 22)
        sections.append(hpad(heroHeader))

        let body = LayoutNode.text(item.blurb, style: theme.label(15, color: theme.inkSecondary))
        sections.append(hpad(body))

        sections.append(hpad(sectionHeader("Highlights")))
        var bullets: [LayoutNode] = []
        for highlight in item.highlights {
            let dot = LayoutNode(.shape(.circle, fill: .color(theme.accent), stroke: nil)).height(7).width(7)
            bullets.append(LayoutNode.hstack(spacing: 10, verticalAlignment: 0.5, [
                dot,
                LayoutNode.text(highlight, style: theme.label(14)),
                LayoutNode.spacer(),
            ]))
        }
        sections.append(hpad(LayoutNode.vstack(spacing: 10, horizontalAlignment: 0, bullets)))

        // Actions
        let liked = state.liked.contains(item.id)
        let saved = state.saved.contains(item.id)
        let likeButton = LayoutNode.text(liked ? "♥  \(item.id + 18)" : "♡  \(item.id + 18)",
                                         style: theme.label(14, .semibold, color: liked ? theme.accent : theme.inkSecondary),
                                         alignment: 0.5)
            .height(46)
            .surfaceFill(.color(liked ? theme.accentSoft : theme.surface), radius: 14)
            .onTap { [weak self] in self?.toggleLike(item.id) }
        let saveButton = LayoutNode.text(saved ? "★  Saved" : "☆  Save",
                                         style: theme.label(14, .semibold, color: saved ? theme.accent : theme.inkSecondary),
                                         alignment: 0.5)
            .height(46)
            .surfaceFill(.color(saved ? theme.accentSoft : theme.surface), radius: 14)
            .onTap { [weak self] in self?.toggleSave(item.id) }
        sections.append(hpad(LayoutNode.hstack(spacing: 10, verticalAlignment: 0.5, [likeButton, saveButton])))
        sections.append(LayoutNode.spacer(minLength: 24))

        return LayoutNode.vstack(spacing: 16, horizontalAlignment: 0, sections)
            .padding(EdgeInsetsLike(top: max(safeArea.top, 16) + 4, bottom: 0, leading: 0, trailing: 0))
    }

    // MARK: - Tab bar

    private func tabBar() -> LayoutNode {
        var items: [LayoutNode] = []
        for tab in Tab.allCases {
            let selected = state.tab == tab && state.detail == nil
            let dot = LayoutNode(.shape(.circle,
                                        fill: .color(selected ? theme.accent : theme.separator),
                                        stroke: nil))
                .height(selected ? 12 : 9)
                .width(selected ? 12 : 9)
            let item = LayoutNode.vstack(spacing: 5, horizontalAlignment: 0.5, [
                dot,
                LayoutNode.text(tab.title,
                                style: theme.label(11, selected ? .semibold : .medium,
                                                   color: selected ? theme.accent : theme.inkTertiary)),
            ])
            .frame(FrameSpec(minWidth: 0, maxWidth: .infinity))
            .onTap { [weak self] in self?.select(tab: tab) }
            items.append(item)
        }
        let row = LayoutNode.hstack(spacing: 0, verticalAlignment: 0.5, items)
            .padding(EdgeInsetsLike(top: 8, bottom: 6 + safeArea.bottom, leading: 0, trailing: 0))
            .height(tabBarHeight)
            .surfaceFill(.color(theme.surface), radius: 0)
        return row.height(tabBarHeight)
    }
}

