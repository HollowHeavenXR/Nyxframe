import Foundation

/// Mirrors the JSON shape produced by `with_urls()` in `lua/src/routes.lua`
/// on the backend. Decoded with `.convertFromSnakeCase`, so `media_kind` ->
/// `mediaKind` etc. Optional almost everywhere on purpose: the backend's
/// response shape varies slightly by endpoint (e.g. locked/adult media strips
/// several fields), and a strict non-optional model would throw on any of
/// those variants.
struct MediaItem: Codable, Identifiable, Hashable {
    var id: Int
    var title: String?
    var description: String?
    /// Where the uploader got the media from. Decoded from `source_url`.
    /// Optional like the rest of this model -- endpoints that strip fields
    /// for locked/adult media omit it entirely.
    var sourceUrl: String?
    var tags: [String]?
    var mediaKind: String?
    var url: String?
    var thumbUrl: String?
    var previewUrl: String?
    var downloadUrl: String?
    var isAdult: Bool?
    var locked: Bool?
    var requiresAdultBlur: Bool?
    var viewerCanOpenAdult: Bool?
    var likedByMe: Bool?
    var bookmarkedByMe: Bool?
    var likeCount: Int?
    var commentCount: Int?
    var views: Int?
    var downloads: Int?
    var fileSize: Int?
    var userId: Int?
    var username: String?
    var displayName: String?
    var userAvatarUrl: String?
    var visibility: String?
    var commentsEnabled: Bool?
    var downloadsEnabled: Bool?
    var pinnedAt: String?
    var publishAt: String?
    var moderationStatus: String?
    var moderationReason: String?
    var categoryId: Int?
    var categoryName: String?
    var subcategoryNames: [String]?
    /// Needed to pre-select the post's existing subcategories when editing;
    /// `subcategoryNames` alone can't be mapped back to ids reliably.
    var subcategoryIds: [Int]?
    var createdAt: String?
    var deletedAt: String?
    var yearsAgo: Int?
    /// True when the uploader picked their own thumbnail for this video.
    /// Only sent on single-post responses.
    var hasCustomThumbnail: Bool?
    /// The stored file plays as-is (MP4, 8-bit H.264, AAC/MP3 or no audio),
    /// so "original" quality can stream it directly instead of the
    /// server's HLS "original" copy -- a full duplicate of the video the
    /// server would otherwise have to write. See routes.lua's
    /// M._direct_playable.
    var directPlay: Bool?

    var isVideo: Bool { mediaKind == "video" }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// `{counts: {emoji: count}, my_reaction: emoji?}` from `/api/media/{id}` and `/react`.
struct ReactionsSummary: Codable {
    var counts: [String: Int]?
    var myReaction: String?
}

struct Comment: Codable, Identifiable {
    var id: Int
    var mediaId: Int?
    var userId: Int?
    var body: String
    var parentCommentId: Int?
    var username: String?
    var displayName: String?
    var userAvatarPath: String?
    var createdAt: String?
    /// Per-comment reaction counts, batched onto `/api/media/{id}` by the
    /// backend. Absent on freshly-posted comments (the add-comment response
    /// has no reactions yet) -- `CommentsSection` treats a nil the same as
    /// an all-zero summary.
    var reactions: ReactionsSummary?
}

struct CategorySummary: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var slug: String?
    var mediaKind: String?
    var subcategories: [SubcategorySummary]?
}

struct SubcategorySummary: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var slug: String?
}

struct CollectionSummary: Codable, Identifiable {
    var id: Int
    var name: String
    var description: String?
    var isPublic: Bool?
    var isSmart: Bool?
    var coverUrl: String?
    var userId: Int?
    var username: String?
    var displayName: String?
    var createdAt: String?
}

struct SavedSearch: Codable, Identifiable {
    var id: Int
    var name: String
    var filterJson: [String: JSONValue]?
    var lastNotifiedAt: String?
    var createdAt: String?
}

struct SiteAnnouncement: Codable {
    var announcementMessage: String?
    var announcementLevel: String?
    var announcementActive: Bool?
    var maintenanceMode: Bool?
    var maintenanceMessage: String?
}

/// Loose JSON value for fields whose shape isn't worth fully modeling
/// (e.g. a saved search's stored filter_json, whose keys vary by filter type).
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
