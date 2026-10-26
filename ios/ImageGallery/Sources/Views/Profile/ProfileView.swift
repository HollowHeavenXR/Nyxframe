import SwiftUI

struct ProfileView: View {
    @StateObject private var viewModel: ProfileViewModel
    @EnvironmentObject private var session: SessionStore


    init(username: String) {
        _viewModel = StateObject(wrappedValue: ProfileViewModel(username: username))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let user = viewModel.user {
                    profileContent(user)
                } else if viewModel.isLoading {
                    ProgressView().padding(.top, 80)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.user?.displayName ?? viewModel.username)
        .nyxScreen()
        .tint(Color(hex: viewModel.user?.userSettings?.accentColor))
        .toolbar {
            if viewModel.user?.friendStatus == "self" {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: FriendRequestsView()) {
                        Image(systemName: "person.badge.clock")
                    }
                    .accessibilityLabel("Friend requests")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: EditProfileView()) {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit profile")
                }
            } else if let user = viewModel.user {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: ProfileLinks.shareURL(username: user.username)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share profile")
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func profileContent(_ user: GalleryUser) -> some View {
        // profile_content_focus reorders/hides collections+friends around
        // the media grid; profile_featured_panel is a separate "Featured…"
        // spotlight section web only actually renders content into for
        // collections/friends (its own ternary: featuredPanel === "uploads"
        // -- the default -- renders nothing extra there, since Posts
        // already covers that case), so mirrored the same way here rather
        // than inventing a "Featured Posts" section web itself doesn't have.
        let focus = user.userSettings?.profileContentFocus ?? "balanced"
        if Appearance.isGridFirstLayout(user.userSettings?.profileLayout) {
            mediaSection
            headerSection(user)
            featuredPanelSection(user)
            focusedSections(focus: focus)
        } else {
            headerSection(user)
            featuredPanelSection(user)
            focusedSections(focus: focus)
        }
    }

    @ViewBuilder
    private func focusedSections(focus: String) -> some View {
        switch focus {
        case "gallery":
            mediaSection
        case "collections":
            collectionsSection
            mediaSection
            friendsSection
        case "social":
            friendsSection
            mediaSection
            collectionsSection
        default:
            mediaSection
            collectionsSection
            friendsSection
        }
    }

    @ViewBuilder
    private func featuredPanelSection(_ user: GalleryUser) -> some View {
        switch user.userSettings?.profileFeaturedPanel {
        case "collections" where !viewModel.collections.isEmpty:
            Text("Featured Collections").font(.headline)
            collectionsRow(Array(viewModel.collections.prefix(4)))
        case "friends" where !viewModel.friends.isEmpty:
            Text("Featured Friends").font(.headline)
            friendsRow(Array(viewModel.friends.prefix(6)), style: "cards")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func headerSection(_ user: GalleryUser) -> some View {
        ProfileHeader(user: user)
        ProfileActionsView(viewModel: viewModel)
    }

    @ViewBuilder
    private var mediaSection: some View {
        if !viewModel.media.isEmpty {
            NyxSectionHeader(eyebrow: "Gallery", title: "Posts")
                .padding(.horizontal, -20)
            NyxMediaGrid(items: viewModel.media, horizontalPadding: 0)
        }
    }

    @ViewBuilder
    private var collectionsSection: some View {
        if !viewModel.collections.isEmpty {
            Text("Collections").font(.headline)
            collectionsRow(viewModel.collections)
        }
    }

    @ViewBuilder
    private var friendsSection: some View {
        if !viewModel.friends.isEmpty {
            Text("Friends").font(.headline)
            friendsRow(viewModel.friends, style: viewModel.user?.userSettings?.profileSocialLayout)
        }
    }

    // profile_card_style, applied to these (previously bare Label rows,
    // not cards at all -- a real functional gap next to web's CollectionMini/
    // UserMini, not just a missing setting). solid/outline/elevated/edge
    // mirror the same corner/shadow/fill treatments media_border_style
    // already established for MediaCard; glass reuses softCard() as-is.
    private func collectionsRow(_ collections: [CollectionSummary]) -> some View {
        VStack(spacing: 8) {
            ForEach(collections) { collection in
                NavigationLink(destination: CollectionDetailView(collectionId: collection.id)) {
                    HStack(spacing: 10) {
                        if let coverUrl = collection.coverUrl, let url = URL(string: coverUrl) {
                            CachedAsyncImage(url: url) { phase in
                                if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "folder").frame(width: 40, height: 40).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Text(collection.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(10)
                    .modifier(ProfileCardBackground(style: viewModel.user?.userSettings?.profileCardStyle))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func friendsRow(_ friends: [GalleryUser], style: String?) -> some View {
        switch style {
        case "rail":
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(friends) { friend in
                        NavigationLink(destination: ProfileView(username: friend.username)) {
                            VStack(spacing: 4) {
                                AvatarView(urlString: friend.avatarUrl, fallbackInitial: String(friend.username.prefix(1)), shape: .circle, size: 52)
                                Text(friend.displayName ?? friend.username).font(.caption2).lineLimit(1).frame(width: 60)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case "cards":
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                ForEach(friends) { friend in
                    NavigationLink(destination: ProfileView(username: friend.username)) {
                        VStack(spacing: 6) {
                            AvatarView(urlString: friend.avatarUrl, fallbackInitial: String(friend.username.prefix(1)), shape: .circle, size: 56)
                            Text(friend.displayName ?? friend.username).font(.caption).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .modifier(ProfileCardBackground(style: viewModel.user?.userSettings?.profileCardStyle))
                    }
                    .buttonStyle(.plain)
                }
            }
        default: // "compact"
            VStack(spacing: 8) {
                ForEach(friends) { friend in
                    NavigationLink(destination: ProfileView(username: friend.username)) {
                        HStack(spacing: 10) {
                            AvatarView(urlString: friend.avatarUrl, fallbackInitial: String(friend.username.prefix(1)), shape: .circle, size: 32)
                            Text(friend.displayName ?? friend.username).font(.subheadline).foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

}

/// Split out of `ProfileView.body` to keep each individual view's expression
/// simple for the type-checker (see the CollectionsListView fix for why).
private struct ProfileHeader: View {
    let user: GalleryUser

    private var accent: Color { Color(hex: user.userSettings?.accentColor) }

    // accent_secondary is optional -- unlike accent_color, an unset/empty
    // value should mean "no second color" (single-color wash), not fall
    // back to re-deriving a default the way Color(hex:) does for the
    // primary accent.
    private var secondaryAccent: Color? {
        guard let hex = user.userSettings?.accentSecondary, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    // "center" stacks the avatar above the text and centers everything,
    // mirroring .profile-align-center's `justify-items: center; text-align:
    // center`. "start"/"split" both keep the side-by-side layout -- web's
    // own CSS difference between them (`align-items: start` vs. the grid's
    // default) is subtle enough at this scale to not warrant two distinct
    // native layouts.
    private var isCenterAligned: Bool { user.userSettings?.profileHeroAlignment == "center" }

    var body: some View {
        VStack(alignment: isCenterAligned ? .center : .leading, spacing: 14) {
            if isCenterAligned {
                VStack(spacing: 10) {
                    avatarView
                    identityBlock(centered: true)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 14) {
                    avatarView
                    identityBlock(centered: false)
                }
            }

            statsRow
        }
        .padding(Metrics.Space.lg)
        .background(headerBackground)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // profile_bg_color is optional -- unset means "no override", not "fall
    // back to a default color".
    private var profileBgColor: Color? {
        guard let hex = user.userSettings?.profileBgColor, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    // Everything BEHIND the header's actual content, composited into one
    // group so profile_surface_opacity/_blur can apply to just this --
    // SwiftUI's .blur(radius:) blurs a view's own content too, unlike
    // CSS's backdrop-filter (which only blurs what's behind an element),
    // so applying it to the header's full VStack would have blurred the
    // avatar/name/stats text right along with the background. Composited
    // separately and placed via .background() specifically to avoid that.
    private var headerBackground: some View {
        ZStack {
            ProfileHeaderBackgroundFill(style: user.userSettings?.profileHeaderStyle, overrideColor: profileBgColor)
            // profile_backdrop_image_url/_strength -- web clamps strength
            // to 0.2-0.55 (user_settings.lua); matched here rather than
            // trusting whatever the stored value is.
            if let backdropUrl = user.userSettings?.profileBackdropImageUrl, !backdropUrl.isEmpty, let url = URL(string: backdropUrl) {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .opacity(min(0.55, max(0.2, user.userSettings?.profileBackdropStrength ?? 0.18)))
                    }
                }
                .clipped()
            }
            AccentWash(color: accent, secondaryColor: secondaryAccent, bannerStyle: user.userSettings?.profileBannerStyle)
        }
        .opacity(user.userSettings?.profileSurfaceOpacity.map { min(1, max(0.2, $0)) } ?? 1)
        .blur(radius: min(24, max(0, user.userSettings?.profileSurfaceBlur ?? 0)))
    }

    private var avatarView: some View {
        AvatarView(urlString: user.avatarUrl, fallbackInitial: String(user.username.prefix(1)), shape: AvatarShape(user.userSettings?.profileAvatarShape), size: 72)
            .overlay(
                RoundedRectangle(cornerRadius: 72 * AvatarShape(user.userSettings?.profileAvatarShape).cornerRadiusFraction)
                    .strokeBorder(accent.opacity(0.6), lineWidth: 2)
            )
    }

    private func identityBlock(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 4) {
            ProfileName(text: user.displayName ?? user.username, style: user.userSettings?.profileNameStyle, accent: accent, secondaryAccent: secondaryAccent)
            Text("@\(user.username)").foregroundStyle(.secondary)
            if user.discordVerifiedAt != nil {
                Label("Discord Verified", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
            }
            if let bio = user.bio, !bio.isEmpty {
                Text(bio).font(.footnote)
                    .multilineTextAlignment(centered ? .center : .leading)
            }
            // The backend already nulls out created_at server-side for a
            // non-owner viewer when profile_show_joined_date is off
            // (routes.lua's decode_user) -- so a missing date here always
            // means "hidden", never "unknown", and this row can just not
            // render rather than needing its own separate owner/viewer
            // check.
            if let joined = DateFormatting.joined(user.createdAt) {
                Label("Joined \(joined)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct StatEntry {
        let label: String
        let value: Int?
        let kind: UserListView.Kind?
    }

    // followerCount/followingCount are already nil'd server-side when the
    // owner has profile_show_follow_counts off -- hide the whole pill
    // rather than showing a misleading "0".
    @ViewBuilder
    private var statsRow: some View {
        let entries: [StatEntry] = [
            StatEntry(label: "Posts", value: user.mediaCount, kind: nil),
            StatEntry(label: "Followers", value: user.followerCount, kind: .followers),
            StatEntry(label: "Following", value: user.followingCount, kind: .following),
            StatEntry(label: "Friends", value: user.friendCount, kind: nil),
        ]
        switch user.userSettings?.profileStatStyle {
        case "ribbon":
            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { Divider().frame(height: 24) }
                    statLink(entry, style: .ribbon)
                }
            }
            .softCard(radius: Metrics.Radius.sm)
        case "minimal":
            HStack(spacing: 16) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    statLink(entry, style: .minimal)
                }
            }
        default:
            HStack(spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    statLink(entry, style: .tiles)
                }
            }
        }
    }

    private enum StatStyle { case tiles, ribbon, minimal }

    @ViewBuilder
    private func statLink(_ entry: StatEntry, style: StatStyle) -> some View {
        if entry.kind == nil {
            statPill(entry.label, entry.value, style: style)
        } else if let value = entry.value, let kind = entry.kind {
            NavigationLink(destination: UserListView(userId: user.id, kind: kind)) {
                statPill(entry.label, value, style: style)
            }
            .buttonStyle(.plain)
        }
    }

    private func statPill(_ label: String, _ value: Int?, style: StatStyle) -> some View {
        Group {
            switch style {
            case .tiles:
                VStack(spacing: 2) {
                    Text("\(value ?? 0)").font(.subheadline).bold()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .softCard(radius: Metrics.Radius.sm)
            case .ribbon:
                VStack(spacing: 2) {
                    Text("\(value ?? 0)").font(.subheadline).bold()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            case .minimal:
                HStack(spacing: 4) {
                    Text("\(value ?? 0)").font(.footnote).bold()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// `profile_name_style` -- mirrors web's three class-based h2 treatments
/// (gradient/glow/outline) plus the plain default ("display"). Outline has
/// no real SwiftUI Text-stroke equivalent (web uses `-webkit-text-stroke`),
/// so it's approximated with bold accent-colored text rather than a true
/// hollow stroke.
private struct ProfileName: View {
    let text: String
    let style: String?
    let accent: Color
    let secondaryAccent: Color?

    var body: some View {
        switch style {
        case "gradient":
            Text(text).font(.title3).bold()
                .foregroundStyle(LinearGradient(colors: [accent, secondaryAccent ?? Color(hex: "#6ec7ff")], startPoint: .topLeading, endPoint: .bottomTrailing))
        case "glow":
            Text(text).font(.title3).bold()
                .shadow(color: accent.opacity(0.5), radius: 10)
        case "outline":
            Text(text).font(.title3).bold()
                .foregroundStyle(accent)
        default:
            Text(text).font(.title3).bold()
        }
    }
}

/// `profile_header_style` -- the AccentWash gradient (already applied
/// underneath by ProfileHeader) stays constant across all five modes; this
/// only changes what sits on top of it, mirroring web's solid/glass/blur/
/// transparent/gradient header treatments.
/// A standalone background fill layer (not a ViewModifier -- it's
/// composited inside ProfileHeader's headerBackground ZStack alongside the
/// backdrop image and AccentWash, rather than wrapping the header's actual
/// content, so profile_surface_opacity/_blur can apply to backgrounds only).
private struct ProfileHeaderBackgroundFill: View {
    let style: String?
    /// `profile_bg_color` -- an explicit override wins outright over
    /// profile_header_style, same as web's `[style*="--profile-bg-override"]`
    /// selector taking precedence by being a plain background-color rule
    /// applied regardless of which `.profile-header-*` class is also active.
    let overrideColor: Color?

    var body: some View {
        if let overrideColor {
            overrideColor
        } else {
            switch style {
            case "solid":
                Color(uiColor: .secondarySystemBackground)
            case "blur":
                Rectangle().fill(.ultraThinMaterial)
            case "transparent", "gradient":
                Color.clear
            default:
                Rectangle().fill(.thinMaterial)
            }
        }
    }
}

/// `profile_card_style` -- mirrors web's five `.profile-card-*` treatments
/// (solid/outline/elevated/edge use a flat fill/no-fill/heavier-shadow/
/// sharp-corner variant of the same softCard() base; "glass" is just
/// softCard() itself, the existing default look).
private struct ProfileCardBackground: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "solid":
            content
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.md, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        case "outline":
            content
                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.md, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        case "elevated":
            content.softCard().cardShadow()
        case "edge":
            content
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.thinMaterial))
        default: // "glass"
            content.softCard()
        }
    }
}

enum ProfileLinks {
    /// Matches the web app's route (`frontend/src/App.jsx`: `/users/:username`,
    /// served under the GitHub Pages basename) so a shared link opens the
    /// same profile there for anyone without the app installed.
    static func shareURL(username: String) -> URL {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        return URL(string: "https://hollowheavenxr.github.io/Nyxframe/users/\(encoded)")
            ?? URL(string: "https://hollowheavenxr.github.io/Nyxframe/")!
    }
}
