// Atlas — a four-screen demo app, written in ordinary SwiftUI and nothing else.
//
// The same source builds twice: as the app on the port (this file is part of the
// SwiftUIAndroidApp target) and, unchanged, as the fidelity probe that
// scripts/port/check-demo.sh typechecks against Apple's retargeted `SwiftUI` interface for
// aarch64 Android. That one file compiles both ways is the port's central claim: the API it is
// written against is Apple's, not a lookalike.
import Combine
import SwiftUI

// MARK: - Models

struct AtlasItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let subtitle: String
    let category: String
    let minutes: Int
    let author: String
    let blurb: String
    let highlights: [String]
}

enum AtlasData {
    static let items: [AtlasItem] = [
        AtlasItem(id: 0, title: "Design tokens 2.0", subtitle: "Colour, type and spacing as data",
                  category: "Systems", minutes: 6, author: "Nadia Okonkwo",
                  blurb: "Tokens move design decisions out of mockups and into code.",
                  highlights: ["One source of truth", "Dark mode derived", "4 pt baseline grid"]),
        AtlasItem(id: 1, title: "Layout without tears", subtitle: "Proposing sizes, not pixels",
                  category: "Layout", minutes: 8, author: "Ivo Martins",
                  blurb: "A parent proposes, a child answers, the parent places.",
                  highlights: ["Stacks distribute leftover space", "Frames clamp the proposal"]),
        AtlasItem(id: 2, title: "Motion with intent", subtitle: "When to move, when to settle",
                  category: "Motion", minutes: 5, author: "Sora Tanaka",
                  blurb: "Motion should explain a change of state, not decorate it.",
                  highlights: ["Enter and exit along the same path", "Duration scales with distance"]),
        AtlasItem(id: 3, title: "Type that breathes", subtitle: "Line height is a design decision",
                  category: "Type", minutes: 7, author: "Lena Fischer",
                  blurb: "Text is the interface; the ladder runs from 34 pt to 11 pt.",
                  highlights: ["Body at 17 pt", "Secondary never below 60% contrast"]),
        AtlasItem(id: 4, title: "Colour on canvas", subtitle: "Gradients that stay tasteful",
                  category: "Colour", minutes: 4, author: "Marek Nowak",
                  blurb: "Two-stop gradients over a solid base, shadow underneath.",
                  highlights: ["Six gradients", "Shadow carries depth"]),
        AtlasItem(id: 5, title: "Shipping the port", subtitle: "What runs, what is next",
                  category: "Engineering", minutes: 9, author: "Port team",
                  blurb: "Swift compiled for Android, drawing through the platform canvas.",
                  highlights: ["Swift runtime", "Android canvas"]),
    ]

    static let gradients: [[Color]] = [
        [Color(red: 0.13, green: 0.83, blue: 0.93), Color(red: 0.23, green: 0.51, blue: 0.96)],
        [Color(red: 0.96, green: 0.45, blue: 0.71), Color(red: 0.98, green: 0.44, blue: 0.52)],
        [Color(red: 0.20, green: 0.83, blue: 0.60), Color(red: 0.06, green: 0.73, blue: 0.51)],
        [Color(red: 0.98, green: 0.75, blue: 0.14), Color(red: 0.98, green: 0.45, blue: 0.09)],
        [Color(red: 0.65, green: 0.55, blue: 0.98), Color(red: 0.43, green: 0.16, blue: 0.85)],
        [Color(red: 0.38, green: 0.65, blue: 0.98), Color(red: 0.15, green: 0.39, blue: 0.92)],
    ]

    static func gradient(for id: Int) -> LinearGradient {
        LinearGradient(colors: gradients[id % gradients.count],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - App state

final class AtlasModel: ObservableObject {
    @Published var tab: Int = 0
    @Published var detail: Int?
    @Published var liked: Set<Int> = []
    @Published var saved: Set<Int> = [2]
    @Published var notifications = true
    @Published var haptics = true
    @Published var compact = false
    @Published var category: Int = 0
}

// MARK: - Components

struct SectionHeader: View {
    let title: String
    var trailing: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 19, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .onTapGesture { action?() }
            }
        }
    }
}

struct CategoryPill: View {
    let text: String
    var selected: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(selected ? .white : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color.gray.opacity(0.18))
            .clipShape(Capsule())
    }
}

struct FeedRow: View {
    let item: AtlasItem

    var body: some View {
        HStack(spacing: 12) {
            Text(String(item.title.prefix(1)))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(AtlasData.gradient(for: item.id))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct GridCard: View {
    let item: AtlasItem
    @Binding var saved: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 14)
                .fill(AtlasData.gradient(for: item.id))
                .frame(height: 96)
                .overlay(alignment: .topLeading) {
                    CategoryPill(text: item.category.uppercased())
                        .padding(8)
                }
            Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(item.subtitle).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
            HStack {
                CategoryPill(text: "\(item.minutes) min")
                Spacer()
                Image(systemName: saved.contains(item.id) ? "star.fill" : "star")
                    .foregroundColor(.accentColor)
                    .onTapGesture {
                        if saved.contains(item.id) { saved.remove(item.id) } else { saved.insert(item.id) }
                    }
            }
        }
    }
}

struct MetricTile: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 24, weight: .bold))
            Text(caption).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SwitchRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Screens

struct HomeScreen: View {
    @ObservedObject var model: AtlasModel
    let open: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Atlas").font(.system(size: 30, weight: .bold))
                        Text("Curated design reading").font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("AT")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(AtlasData.gradient(for: 0))
                        .clipShape(Circle())
                        .onTapGesture { model.tab = 2 }
                }
                .padding(.horizontal, 20)

                heroCard(AtlasData.items[0], open: open)
                    .padding(.horizontal, 20)

                SectionHeader(title: "Continue reading", trailing: "See all") { model.tab = 1 }
                    .padding(.horizontal, 20)

                HStack(spacing: 12) {
                    ForEach(AtlasData.items[1...2]) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(AtlasData.gradient(for: item.id))
                                .frame(height: 78)
                            Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(item.subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                        }
                        .onTapGesture { open(item.id) }
                    }
                }
                .padding(.horizontal, 20)

                SectionHeader(title: "This month").padding(.horizontal, 20)

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        MetricTile(value: "128", caption: "screens")
                        MetricTile(value: "4.9", caption: "rating")
                    }
                    HStack(spacing: 12) {
                        MetricTile(value: "12k", caption: "users")
                        MetricTile(value: "36", caption: "components")
                    }
                }
                .padding(.horizontal, 20)

                SectionHeader(title: "Latest").padding(.horizontal, 20)

                VStack(spacing: 10) {
                    ForEach(AtlasData.items[1...4]) { item in
                        FeedRow(item: item).onTapGesture { open(item.id) }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 24)
            .padding(.bottom, 96)
        }
    }

    @ViewBuilder
    private func heroCard(_ item: AtlasItem, open: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CategoryPill(text: item.category.uppercased())
            Text(item.title).font(.system(size: 27, weight: .bold)).foregroundColor(.white)
            Text(item.subtitle).font(.system(size: 14, weight: .medium)).foregroundColor(.white.opacity(0.85))
            Spacer(minLength: 8)
            HStack {
                Text("Read · \(item.minutes) min")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "arrow.right").foregroundColor(.white)
            }
        }
        .padding(22)
        .frame(height: 212)
        .background(AtlasData.gradient(for: item.id))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        .onTapGesture { open(item.id) }
    }
}

struct DiscoverScreen: View {
    @ObservedObject var model: AtlasModel
    let open: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Discover").font(.system(size: 30, weight: .bold))
                    Text("6 collections · updated today")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    Text("Search components").font(.system(size: 14)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)

                HStack(spacing: 8) {
                    ForEach(Array(["All", "Systems", "Layout", "Motion"].enumerated()), id: \.offset) { index, name in
                        CategoryPill(text: name, selected: model.category == index)
                            .onTapGesture { model.category = index }
                    }
                }
                .padding(.horizontal, 20)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(AtlasData.items) { item in
                        GridCard(item: item, saved: $model.saved)
                            .onTapGesture { open(item.id) }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 24)
            .padding(.bottom, 96)
        }
    }
}

struct ProfileScreen: View {
    @ObservedObject var model: AtlasModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Text("AT")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 76, height: 76)
                        .background(AtlasData.gradient(for: 0))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Atlas Member").font(.system(size: 22, weight: .bold))
                        Text("@atlas · design systems").font(.system(size: 13)).foregroundColor(.secondary)
                        CategoryPill(text: "Pro")
                    }
                }
                .padding(.horizontal, 20)

                HStack(spacing: 10) {
                    MetricTile(value: "42", caption: "Saved")
                    MetricTile(value: "18", caption: "Likes")
                    MetricTile(value: "7", caption: "Streak")
                }
                .padding(.horizontal, 20)

                SectionHeader(title: "Preferences").padding(.horizontal, 20)

                VStack(spacing: 10) {
                    SwitchRow(title: "Notifications", subtitle: "New collections and replies", isOn: $model.notifications)
                    SwitchRow(title: "Haptics", subtitle: "Subtle feedback on taps", isOn: $model.haptics)
                    SwitchRow(title: "Compact rows", subtitle: "Denser feed layout", isOn: $model.compact)
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 24)
            .padding(.bottom, 96)
        }
    }
}

struct DetailScreen: View {
    let item: AtlasItem
    @ObservedObject var model: AtlasModel
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: close) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 8) {
                    CategoryPill(text: item.category.uppercased())
                    Text(item.title).font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                    Text(item.subtitle).font(.system(size: 14, weight: .medium)).foregroundColor(.white.opacity(0.85))
                    Spacer(minLength: 6)
                    Text("\(item.author) · \(item.minutes) min read")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.75))
                }
                .padding(20)
                .frame(height: 196)
                .background(AtlasData.gradient(for: item.id))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 20)

                Text(item.blurb)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)

                SectionHeader(title: "Highlights").padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.highlights, id: \.self) { highlight in
                        HStack(spacing: 10) {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            Text(highlight).font(.system(size: 14))
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 20)

                HStack(spacing: 10) {
                    Button {
                        if model.liked.contains(item.id) { model.liked.remove(item.id) } else { model.liked.insert(item.id) }
                    } label: {
                        Text(model.liked.contains(item.id) ? "♥ Liked" : "♡ Like")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        if model.saved.contains(item.id) { model.saved.remove(item.id) } else { model.saved.insert(item.id) }
                    } label: {
                        Text(model.saved.contains(item.id) ? "★ Saved" : "☆ Save")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
    }
}

struct TabBar: View {
    @ObservedObject var model: AtlasModel

    var body: some View {
        HStack {
            tabItem(0, "Home")
            tabItem(1, "Discover")
            tabItem(2, "Profile")
        }
        .padding(.top, 10)
        .padding(.bottom, 24)
        .background(Color.white)
    }

    private func tabItem(_ index: Int, _ title: String) -> some View {
        VStack(spacing: 5) {
            Circle()
                .fill(model.tab == index && model.detail == nil ? Color.accentColor : Color.gray.opacity(0.3))
                .frame(width: model.tab == index ? 12 : 9, height: model.tab == index ? 12 : 9)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(model.tab == index ? .accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .onTapGesture {
            model.tab = index
            model.detail = nil
        }
    }
}

struct AtlasRootView: View {
    @StateObject private var model = AtlasModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let id = model.detail, let item = AtlasData.items.first(where: { $0.id == id }) {
                    DetailScreen(item: item, model: model) { model.detail = nil }
                } else if model.tab == 0 {
                    HomeScreen(model: model) { model.detail = $0 }
                } else if model.tab == 1 {
                    DiscoverScreen(model: model) { model.detail = $0 }
                } else {
                    ProfileScreen(model: model)
                }
            }
            TabBar(model: model)
        }
        .background(Color(white: 0.96))
    }
}
