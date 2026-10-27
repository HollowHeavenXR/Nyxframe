import Foundation

// MARK: - Admin: user management
//
// Site-owner-only endpoints (lua/src/routes.lua's "Admin: user management"
// section). Platform-neutral on purpose -- this file is compiled into the
// tvOS target too (Services/ is shared), even though only the iOS app shows
// an admin screen.

struct AdminUser: Decodable, Identifiable, Hashable {
    var id: Int
    var username: String
    var displayName: String?
    var email: String?
    var profileColor: String?
    var avatarUrl: String?
    var createdAt: String?
    var lastSeenAt: String?
    var bannedAt: String?
    var bannedUntil: String?
    var banReason: String?
    var ageVerifiedAt: String?
    var siteOwner: Bool?
    var banned: Bool?
    var postCount: Int?
    var commentCount: Int?
    var likeCount: Int?
    var collectionCount: Int?
    var storageBytes: Int?
    /// Only on the single-user summary: false for the site owner and for
    /// the admin's own account.
    var canDelete: Bool?

    var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return username
    }

    static func == (lhs: AdminUser, rhs: AdminUser) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Everything a permanent delete removes, counted.
struct AdminUserCounts: Decodable {
    var posts: Int?
    var videos: Int?
    var images: Int?
    var storageBytes: Int?
    var comments: Int?
    var commentsFromOthers: Int?
    var likes: Int?
    var bookmarks: Int?
    var collections: Int?
    var followers: Int?
    var following: Int?
    var messages: Int?
}

struct AdminUsersResponse: Decodable { var users: [AdminUser]; var hasMore: Bool?; var totalUsers: Int? }
struct AdminUserSummaryResponse: Decodable { var user: AdminUser; var counts: AdminUserCounts }
struct AdminDeleteUserResponse: Decodable { var deleted: Bool; var username: String?; var removed: AdminUserCounts? }

extension GalleryAPIClient {
    private struct BanBody: Encodable { var reason: String?; var until: String? }
    private struct DeleteUserBody: Encodable { var confirmUsername: String }

    /// `filter`: all / active / banned. `sort`: newest / oldest / posts /
    /// last_seen / storage / name.
    func adminUsers(query: String, filter: String, sort: String, limit: Int = 40, offset: Int = 0) async throws -> AdminUsersResponse {
        var params = ["filter": filter, "sort": sort, "limit": String(limit), "offset": String(offset)]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { params["q"] = trimmed }
        return try await requestJSON("/api/admin/users", query: params)
    }

    func adminUserSummary(id: Int) async throws -> AdminUserSummaryResponse {
        try await requestJSON("/api/admin/users/\(id)")
    }

    /// `until`: ISO-8601 timestamp, or nil for a permanent ban.
    func adminBanUser(id: Int, reason: String?, until: String?) async throws {
        let _: UnreadCountResponseOrIgnore = try await requestJSON("/api/admin/users/\(id)/ban", body: BanBody(reason: reason, until: until))
    }

    func adminUnbanUser(id: Int) async throws {
        let _: UnreadCountResponseOrIgnore = try await requestJSON("/api/admin/users/\(id)/unban", body: EmptyBody())
    }

    /// Permanent: the server requires the username typed back exactly.
    func adminDeleteUser(id: Int, confirmUsername: String) async throws -> AdminDeleteUserResponse {
        try await requestJSON("/api/admin/users/\(id)/delete", body: DeleteUserBody(confirmUsername: confirmUsername))
    }
}

// MARK: - Custom video thumbnails + reuse-tags picker

/// One of the signed-in user's own tagged posts, for the "reuse tags"
/// picker (`GET /api/me/media/picker`).
struct PostPickerItem: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String?
    var mediaKind: String?
    var categoryName: String?
    var tags: [String]?
    var thumbUrl: String?

    static func == (lhs: PostPickerItem, rhs: PostPickerItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PostPickerResponse: Decodable { var items: [PostPickerItem]; var hasMore: Bool? }
struct ThumbnailTokenResponse: Decodable { var thumbnailToken: String }

extension GalleryAPIClient {
    /// q matches title or tag; a post id or pasted post link finds that post.
    func postPicker(query: String, offset: Int = 0, limit: Int = 36) async throws -> PostPickerResponse {
        var params = ["offset": String(offset), "limit": String(limit)]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { params["q"] = trimmed }
        return try await requestJSON("/api/me/media/picker", query: params)
    }

    /// Sends a chosen thumbnail ahead of a video upload; the returned token
    /// rides along with the upload (`UploadFields.thumbnailToken`) and the
    /// server attaches it once the post exists.
    func stageUploadThumbnail(jpegData: Data) async throws -> String {
        let file = MultipartFile(fieldName: "file", fileName: "thumbnail.jpg", mimeType: "image/jpeg", source: .data(jpegData))
        let response: ThumbnailTokenResponse = try await upload("/api/media/upload/thumbnail", fields: [:], file: file)
        return response.thumbnailToken
    }

    func setMediaThumbnail(mediaId: Int, jpegData: Data) async throws -> MediaItem {
        let file = MultipartFile(fieldName: "file", fileName: "thumbnail.jpg", mimeType: "image/jpeg", source: .data(jpegData))
        let response: MediaResponse = try await upload("/api/media/\(mediaId)/thumbnail", fields: [:], file: file)
        await APIResponseCache.shared.invalidate(pathPrefix: "/api/media")
        await APIResponseCache.shared.invalidate(pathPrefix: "/api/me/media")
        return response.media
    }

    func clearMediaThumbnail(mediaId: Int) async throws -> MediaItem {
        let response: MediaResponse = try await requestJSON("/api/media/\(mediaId)/thumbnail", method: "DELETE")
        await APIResponseCache.shared.invalidate(pathPrefix: "/api/media")
        await APIResponseCache.shared.invalidate(pathPrefix: "/api/me/media")
        return response.media
    }
}
