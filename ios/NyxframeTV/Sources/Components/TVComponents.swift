import SwiftUI

// MARK: - Navigation

/// Every push destination in the TV app. One enum so each tab's
/// NavigationStack can resolve the same set of screens.
enum TVRoute: Hashable {
    case media(id: Int, siblings: [Int])
    case user(String)
    case collection(Int)
    case directMessages(userId: Int, name: String)
    case groupThread(id: Int, name: String)
    case slideshow(items: [MediaItem])
}

/// Owns one tab's navigation stack, so any screen in that tab can push a
/// destination from code (a card's action, "Surprise Me", a notification).
@MainActor
final class TVNavigator: ObservableObject {
    @Published var path = NavigationPath()

    func push(_ route: TVRoute) { path.append(route) }

    func openMedia(_ item: MediaItem, in list: [MediaItem]) {
        push(.media(id: item.id, siblings: list.map(\.id)))
    }

    func popToRoot() { path = NavigationPath() }
}

/// A tab's NavigationStack wired to its own navigator and every route.
struct TVTabStack<Content: View>: View {
    @StateObject private var navigator = TVNavigator()
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $navigator.path) {
            content().tvRouteDestinations()
        }
        .environmentObject(navigator)
    }
}

extension View {
    /// Registers every `TVRoute` destination on the enclosing
    /// NavigationStack.
    func tvRouteDestinations() -> some View {
        navigationDestination(for: TVRoute.self) { route in
            switch route {
            case .media(let id, let siblings):
                MediaDetailScreen(mediaId: id, siblings: siblings)
            case .user(let username):
                ProfileScreen(username: username)
            case .collection(let id):
                CollectionDetailScreen(collectionId: id)
            case .directMessages(let userId, let name):
                DirectMessageScreen(userId: userId, name: name)
            case .groupThread(let id, let name):
                GroupThreadScreen(threadId: id, name: name)
            case .slideshow(let items):
                SlideshowScreen(items: items)
            }
        }
    }
}

// MARK: - Palette

enum TVTheme {
    static let accent = Color(hex: Appearance.defaultAccentHex)
    static let background = LinearGradient(
        colors: [Color(red: 0.04, green: 0.07, blue: 0.10), Color(red: 0.05, green: 0.12, blue: 0.13)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let gridSpacing: CGFloat = 44
    static let gridColumns = 4
}

struct TVScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        // Every screen sits on the synced, crossfading site background --
        // the same image the website is showing right now.
        content.background(TVSiteBackdrop())
    }
}

extension View {
    func tvScreenBackground() -> some View { modifier(TVScreenBackground()) }
}

// MARK: - Media card

/// A focusable poster for one post. Uses tvOS's `.card` button style, which
/// gives the native lift-and-parallax focus effect.
struct TVMediaCard: View {
    let item: MediaItem
    /// Fixed width for shelves; nil fills the grid column it sits in.
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // A 16:9 frame the thumbnail fills and is cropped to, so an
                // image of any shape can never push the card out of its
                // column or spill over its neighbours.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { TVMediaThumbnail(item: item) }
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title?.nilIfEmpty ?? "Untitled")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(item.displayName ?? item.username ?? "Nyxframe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width)
        }
        .buttonStyle(.card)
    }
}

struct TVMediaThumbnail: View {
    let item: MediaItem

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if item.locked == true {
                ZStack {
                    Color.black.opacity(0.6)
                    VStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.title2)
                        Text("18+").font(.caption.bold())
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                CachedAsyncImage(url: item.thumbUrl.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: item.isVideo ? "film" : "photo").font(.title).foregroundStyle(.secondary)
                        }
                    default:
                        Color.white.opacity(0.06)
                    }
                }
                .blur(radius: item.requiresAdultBlur == true ? 30 : 0)
            }
            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .padding(10)
                    // Solid tint instead of a material: a live blur per card
                    // is costly on Apple TV HD, especially during the focus
                    // lift animation.
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(12)
            }
        }
    }
}

// MARK: - Grid & shelves

/// A vertically scrolling grid of media cards that asks for the next page
/// as focus approaches the end.
struct TVMediaGrid: View {
    let items: [MediaItem]
    var onReachEnd: ((MediaItem) -> Void)?
    let onSelect: (MediaItem, [MediaItem]) -> Void

    /// Always four across. Spacing leaves room for the focused card's lift
    /// so it grows over the gap, never under its neighbour.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: TVTheme.gridSpacing, alignment: .top), count: TVTheme.gridColumns)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: TVTheme.gridSpacing) {
            ForEach(items) { item in
                TVMediaCard(item: item) { onSelect(item, items) }
                    .onAppear { onReachEnd?(item) }
            }
        }
        .focusSection()
    }
}

/// A titled horizontal row of cards -- the classic TV "shelf".
struct TVMediaShelf: View {
    let title: String
    let items: [MediaItem]
    let onSelect: (MediaItem, [MediaItem]) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: TVTheme.gridSpacing) {
                        ForEach(items) { item in
                            TVMediaCard(item: item, width: 340) { onSelect(item, items) }
                        }
                    }
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

// MARK: - People

struct TVAvatar: View {
    let urlString: String?
    let name: String
    var size: CGFloat = 72

    var body: some View {
        CachedAsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    TVTheme.accent.opacity(0.35)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct TVUserChip: View {
    let username: String
    let displayName: String?
    let avatarUrl: String?
    var subtitle: String?

    var body: some View {
        NavigationLink(value: TVRoute.user(username)) {
            HStack(spacing: 20) {
                TVAvatar(urlString: avatarUrl, name: displayName ?? username, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName ?? username).font(.headline)
                    Text(subtitle ?? "@\(username)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - States

struct TVLoadingView: View {
    var label = "Loading…"
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }
}

struct TVMessageView: View {
    let systemImage: String
    let title: String
    var message: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: systemImage).font(.system(size: 64)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            if let message { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let retry {
                Button("Try Again", action: retry)
            }
        }
        .frame(maxWidth: 900, minHeight: 400)
        .frame(maxWidth: .infinity)
    }
}

/// Shown on screens that need an account, with a jump to the Account tab.
struct TVSignInPrompt: View {
    let reason: String
    @EnvironmentObject private var tabs: TVTabRouter

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 72)).foregroundStyle(TVTheme.accent)
            Text("Sign in to Nyxframe").font(.title2.bold())
            Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Go to Sign In") { tabs.selection = .account }
        }
        .frame(maxWidth: 900, minHeight: 500)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pills

struct TVPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .bold : .regular))
                .padding(.horizontal, 8)
        }
        .tint(isSelected ? TVTheme.accent : nil)
        .buttonStyle(.bordered)
    }
}

extension Int {
    /// 1234 -> "1.2K", like the web app's numberish().
    var compactString: String {
        switch self {
        case 1_000_000...: return String(format: "%.1fM", Double(self) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(self) / 1_000)
        default: return String(self)
        }
    }
}
