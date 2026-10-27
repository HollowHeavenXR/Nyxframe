import SwiftUI

/// Site-owner admin: every account with activity counts, searchable,
/// filterable and sortable; tap one for its detail (ban / unban /
/// permanent delete). Mirrors the web admin's Users tab
/// (frontend/src/pages/AdminPage.jsx) on top of the same endpoints.
struct AdminUsersView: View {
    @State private var query = ""
    @State private var filter = "all"
    @State private var sort = "newest"
    @State private var users: [AdminUser] = []
    @State private var totalUsers: Int?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var generation = 0

    private static let sorts: [(String, String)] = [
        ("newest", "Newest"), ("oldest", "Oldest"), ("posts", "Most posts"),
        ("last_seen", "Recently active"), ("storage", "Most storage"), ("name", "Name"),
    ]

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    Text("All").tag("all")
                    Text("Active").tag("active")
                    Text("Banned").tag("banned")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            } footer: {
                if let totalUsers {
                    Text("\(totalUsers) account\(totalUsers == 1 ? "" : "s") in total")
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }

            Section {
                ForEach(users) { user in
                    NavigationLink {
                        AdminUserDetailView(userId: user.id, initial: user) { change in
                            switch change {
                            case .updated(let updated):
                                if let index = users.firstIndex(where: { $0.id == updated.id }) {
                                    users[index] = updated
                                }
                            case .deleted(let id):
                                users.removeAll { $0.id == id }
                                if let totalUsers { self.totalUsers = totalUsers - 1 }
                            }
                        }
                    } label: {
                        row(user)
                    }
                    .onAppear {
                        if user.id == users.last?.id, hasMore, !isLoading {
                            Task { await load(reset: false) }
                        }
                    }
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if users.isEmpty {
                    Text("No users found.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Username, name or email")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Self.sorts, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
            }
        }
        .refreshable { await load(reset: true) }
        .task(id: "\(query)|\(filter)|\(sort)") {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            if Task.isCancelled { return }
            await load(reset: true)
        }
        .nyxScreen()
    }

    private func row(_ user: AdminUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(urlString: user.avatarUrl, fallbackInitial: String(user.name.prefix(1)), size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if user.siteOwner == true { badge("Owner", .accentColor) }
                    if user.banned == true { badge("Banned", .red) }
                }
                Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                Text("\(user.postCount ?? 0) posts · \(user.commentCount ?? 0) comments · \(ByteCountFormatter.string(fromByteCount: Int64(user.storageBytes ?? 0), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(Nyx.mist)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func load(reset: Bool) async {
        if reset { generation += 1 }
        let myGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if myGeneration == generation { isLoading = false } }
        do {
            let response = try await GalleryAPIClient.shared.adminUsers(query: query, filter: filter, sort: sort, offset: reset ? 0 : users.count)
            guard myGeneration == generation else { return }
            users = reset ? response.users : users + response.users
            hasMore = response.hasMore ?? false
            totalUsers = response.totalUsers
        } catch {
            if !error.isCancellation, myGeneration == generation { errorMessage = error.localizedDescription }
        }
    }
}

enum AdminUserChange {
    case updated(AdminUser)
    case deleted(Int)
}

/// One account: stats, ban / unban, and permanent delete (the username
/// must be typed back, then confirmed once more).
struct AdminUserDetailView: View {
    let userId: Int
    let initial: AdminUser
    let onChange: (AdminUserChange) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var user: AdminUser?
    @State private var counts: AdminUserCounts?
    @State private var errorMessage: String?
    @State private var isBusy = false
    @State private var banReason = ""
    @State private var banDays = 7
    @State private var confirmText = ""
    @State private var showingFinalConfirm = false
    @State private var notice: String?

    private var shown: AdminUser { user ?? initial }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AvatarView(urlString: shown.avatarUrl, fallbackInitial: String(shown.name.prefix(1)), size: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shown.name).font(.headline)
                        Text("@\(shown.username)").font(.subheadline).foregroundStyle(.secondary)
                        if let email = shown.email, !email.isEmpty {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    ProfileView(username: shown.username)
                } label: {
                    Label("View profile", systemImage: "person.crop.square")
                }
            } footer: {
                Text("Joined \(DateFormatting.relative(shown.createdAt)) · \(shown.lastSeenAt == nil ? "never seen" : "last seen \(DateFormatting.relative(shown.lastSeenAt))")")
            }

            if let counts {
                Section("Activity") {
                    stat("Posts", counts.posts, detail: "\(counts.videos ?? 0) videos · \(counts.images ?? 0) images")
                    stat("Storage", nil, detail: ByteCountFormatter.string(fromByteCount: Int64(counts.storageBytes ?? 0), countStyle: .file))
                    stat("Comments", counts.comments)
                    stat("Likes", counts.likes)
                    stat("Collections", counts.collections)
                    stat("Followers", counts.followers)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
            if let notice {
                Text(notice).foregroundStyle(.green).font(.footnote)
            }

            if shown.siteOwner == true {
                Section { Text("This is the site owner's account.").foregroundStyle(.secondary) }
            } else {
                banSection
            }

            if user?.canDelete == true, let counts {
                deleteSection(counts)
            }
        }
        .navigationTitle(shown.name)
        .navigationBarTitleDisplayMode(.inline)
        .nyxScreen()
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            "Permanently delete @\(shown.username)?",
            isPresented: $showingFinalConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete @\(shown.username) forever", role: .destructive) {
                Task { await deleteUser() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their account, posts, comments, likes and collections are removed. This can't be undone.")
        }
    }

    @ViewBuilder
    private var banSection: some View {
        Section {
            if shown.banned == true {
                Text(shown.bannedUntil.map { "Banned until \(DateFormatting.relative($0))" } ?? "Banned permanently")
                if let reason = shown.banReason, !reason.isEmpty {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await run({ try await GalleryAPIClient.shared.adminUnbanUser(id: userId) }, done: "Unbanned.") }
                } label: {
                    Label("Unban", systemImage: "checkmark.circle")
                }
                .disabled(isBusy)
            } else {
                TextField("Reason (shown to them)", text: $banReason)
                Picker("Length", selection: $banDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("1 year").tag(365)
                    Text("Permanent").tag(0)
                }
                Button(role: .destructive) {
                    let until = banDays > 0
                        ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(banDays) * 86_400))
                        : nil
                    let reason = banReason.trimmingCharacters(in: .whitespaces)
                    Task {
                        await run({
                            try await GalleryAPIClient.shared.adminBanUser(id: userId, reason: reason.isEmpty ? nil : reason, until: until)
                        }, done: "Banned.")
                    }
                } label: {
                    Label("Ban", systemImage: "nosign")
                }
                .disabled(isBusy)
            }
        } header: {
            Text("Ban")
        }
    }

    private func deleteSection(_ counts: AdminUserCounts) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                removal("\(counts.posts ?? 0) posts (\(ByteCountFormatter.string(fromByteCount: Int64(counts.storageBytes ?? 0), countStyle: .file)))")
                removal("\(counts.comments ?? 0) comments they wrote")
                removal("\(counts.commentsFromOthers ?? 0) comments others left on their posts")
                removal("\(counts.likes ?? 0) likes · \(counts.bookmarks ?? 0) bookmarks")
                removal("\(counts.collections ?? 0) collections")
                removal("\(counts.followers ?? 0) followers · \(counts.following ?? 0) following")
                removal("\(counts.messages ?? 0) messages they sent")
            }
            .font(.footnote)
            TextField("Type \(shown.username) to confirm", text: $confirmText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(role: .destructive) {
                showingFinalConfirm = true
            } label: {
                Label(isBusy ? "Deleting…" : "Permanently delete account", systemImage: "trash")
            }
            .disabled(isBusy || confirmText != shown.username)
        } header: {
            Text("Delete account permanently")
        } footer: {
            Text("This can't be undone. Chats they started stay with the other members; only their own messages go.")
        }
    }

    private func removal(_ text: String) -> some View {
        Label(text, systemImage: "minus.circle").labelStyle(.titleAndIcon).foregroundStyle(.red)
    }

    private func stat(_ label: String, _ value: Int?, detail: String? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let value { Text("\(value)").font(.body.monospacedDigit().weight(.semibold)) }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func load() async {
        do {
            let response = try await GalleryAPIClient.shared.adminUserSummary(id: userId)
            user = response.user
            counts = response.counts
            onChange(.updated(response.user))
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    private func run(_ action: @escaping () async throws -> Void, done: String) async {
        isBusy = true
        errorMessage = nil
        notice = nil
        defer { isBusy = false }
        do {
            try await action()
            notice = done
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteUser() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await GalleryAPIClient.shared.adminDeleteUser(id: userId, confirmUsername: confirmText)
            await APIResponseCache.shared.invalidate(pathPrefix: "/api/")
            Haptics.light()
            onChange(.deleted(userId))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
