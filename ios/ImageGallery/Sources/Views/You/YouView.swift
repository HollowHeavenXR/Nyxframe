import SwiftUI

/// You -- the signed-in viewer's own corner: an identity card wearing their
/// accent, a creator snapshot that opens Studio, and the account doors
/// (public profile, edit, friend requests, collections, settings). Studio
/// used to be a whole tab and the profile another; both are things you
/// visit about yourself, so they live together here.
struct YouView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var studio = StudioViewModel()
    @StateObject private var friendRequests = FriendRequestsViewModel()

    private var user: GalleryUser? { session.currentUser }
    private var accent: Color { Color(hex: user?.userSettings?.accentColor) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let user {
                    identityCard(user)
                    creatorSnapshot
                    doors(user)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .nyxScreen(stars: true)
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .refreshable {
            await session.refreshCurrentUser()
            await studio.load()
            await friendRequests.load()
        }
        .task {
            if studio.items.isEmpty { await studio.load() }
            await friendRequests.load()
        }
    }

    // MARK: Identity

    private func identityCard(_ user: GalleryUser) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                AvatarView(
                    urlString: user.avatarUrl,
                    fallbackInitial: String((user.displayName?.nilIfEmpty ?? user.username).prefix(1)),
                    shape: AvatarShape(user.userSettings?.profileAvatarShape),
                    size: 78
                )
                .overlay(
                    Circle()
                        .strokeBorder(AngularGradient(colors: [accent, .purple, accent], center: .center), lineWidth: 2.5)
                        .padding(-5)
                )
                .padding(5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(user.displayName?.nilIfEmpty ?? user.username)
                        .font(Nyx.display(24))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("@\(user.username)")
                        .font(.subheadline)
                        .foregroundStyle(Nyx.mist)
                    if let headline = user.profileHeadline?.nilIfEmpty ?? user.bio?.nilIfEmpty {
                        Text(headline)
                            .font(.footnote)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
            }

            HStack(spacing: 0) {
                stat(user.mediaCount, "Posts")
                divider
                NavigationLink {
                    UserListView(userId: user.id, kind: .followers)
                } label: {
                    stat(user.followerCount, "Followers")
                }
                .buttonStyle(.plain)
                divider
                NavigationLink {
                    UserListView(userId: user.id, kind: .following)
                } label: {
                    stat(user.followingCount, "Following")
                }
                .buttonStyle(.plain)
                divider
                stat(user.friendCount, "Friends")
            }
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 10) {
                NavigationLink {
                    ProfileView(username: user.username)
                } label: {
                    Label("View profile", systemImage: "person.crop.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NyxPrimaryButtonStyle())

                NavigationLink {
                    EditProfileView()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 52, height: 52)
                        .nyxGlass(radius: 18)
                }
                .buttonStyle(NyxPressStyle())
                .accessibilityLabel("Edit profile")

                ShareLink(item: ProfileLinks.shareURL(username: user.username)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 52, height: 52)
                        .nyxGlass(radius: 18)
                }
                .buttonStyle(NyxPressStyle())
                .accessibilityLabel("Share profile")
            }
        }
        .padding(18)
        .background(
            AccentWash(
                color: accent,
                secondaryColor: user.userSettings?.accentSecondary?.nilIfEmpty.map { Color(hex: $0) },
                bannerStyle: user.userSettings?.profileBannerStyle
            )
            .clipShape(RoundedRectangle(cornerRadius: Nyx.Radius.panel, style: .continuous))
        )
        .nyxGlass(radius: Nyx.Radius.panel, elevated: true)
    }

    private var divider: some View {
        Rectangle().fill(Nyx.hairline).frame(width: 1, height: 28)
    }

    private func stat(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { "\($0)" } ?? "–")
                .font(.system(.headline, design: .rounded).weight(.heavy))
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Nyx.mist)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Studio

    private var creatorSnapshot: some View {
        let active = studio.items.filter { $0.deletedAt == nil }
        let views = active.reduce(0) { $0 + ($1.views ?? 0) }
        let likes = active.reduce(0) { $0 + ($1.likeCount ?? 0) }
        let scheduled = active.filter { item in
            guard let publishAt = DateFormatting.parse(item.publishAt) else { return false }
            return publishAt > Date()
        }.count

        return NavigationLink {
            StudioView()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CREATOR")
                            .font(Nyx.eyebrow)
                            .tracking(1.4)
                            .foregroundStyle(Color.accentColor)
                        Text("Studio")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                        .foregroundStyle(Color.accentColor)
                }

                HStack(spacing: 10) {
                    snapshotTile(value: active.count, label: "Posts", icon: "photo.stack")
                    snapshotTile(value: views, label: "Views", icon: "eye")
                    snapshotTile(value: likes, label: "Likes", icon: "heart")
                }

                if scheduled > 0 {
                    Label("\(scheduled) scheduled to publish", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Nyx.mist)
                }
            }
            .padding(18)
            .nyxGlass(radius: Nyx.Radius.panel)
        }
        .buttonStyle(NyxPressStyle(scale: 0.98))
    }

    private func snapshotTile(value: Int, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Nyx.mist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Doors

    private func doors(_ user: GalleryUser) -> some View {
        VStack(spacing: 0) {
            door("Friend requests", icon: "person.badge.clock.fill", tint: .orange, badge: friendRequests.incoming.count) {
                FriendRequestsView()
            }
            separator
            door("Collections", icon: "square.stack.3d.up.fill", tint: .indigo) {
                CollectionsListView()
            }
            separator
            door("Liked posts", icon: "heart.fill", tint: .pink) {
                FollowingLikedView(mode: .liked)
            }
            separator
            door("Settings", icon: "gearshape.fill", tint: .gray) {
                SettingsView()
            }
            // Site owner only (the server enforces it too).
            if user.siteOwner == true {
                separator
                door("Admin · Users", icon: "shield.lefthalf.filled", tint: .red) {
                    AdminUsersView()
                }
            }
        }
        .nyxGlass(radius: Nyx.Radius.card)
    }

    private var separator: some View {
        Rectangle().fill(Nyx.hairline).frame(height: 1).padding(.leading, 60)
    }

    private func door<Destination: View>(_ title: String, icon: String, tint: Color, badge: Int = 0, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.pink, in: Capsule())
                        .foregroundStyle(.white)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Nyx.mist)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
