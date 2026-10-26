import Foundation

/// Resolves the current backend origin. The web frontend solves "the
/// Cloudflare tunnel URL rotates" by fetching `live-config.json` from GitHub
/// Pages at request time with a whole retry/offline-poll system
/// (`frontend/src/api.js`); this is a deliberately simplified port for v1:
/// fetch once at launch (plus a manual "Refresh" in Settings), and let the
/// user override it entirely for local development.
final class LiveConfigService {
    static let shared = LiveConfigService()

    private static let overrideKey = "gallery_backend_url_override"
    private static let cachedKey = "gallery_backend_url_cached"
    private static let liveConfigURL = URL(string: "https://hollowheavenxr.github.io/Nyxframe/live-config.json")!

    // The backend now sits behind a stable Cloudflare custom domain
    // (GALLERY_TUNNEL_PROVIDER=static in the server's .env), not a
    // rotating quick-tunnel URL the way this class's original design
    // comment above assumed -- confirmed live: it hasn't changed across
    // this whole session. Used only as a last resort, when nothing has
    // ever been cached yet AND the live-config.json fetch fails, so a
    // fresh install isn't left with a genuinely empty origin (confirmed
    // live: this actually happened -- GitHub Pages was never enabled for
    // this repo, so every fresh install's very first launch 404'd on
    // live-config.json with nothing cached from a prior run to fall back
    // on, i.e. exactly "the app doesn't have the backend integrated").
    // Pages is fixed now too, but this removes a fresh install's hard
    // dependency on a third-party static host being up at that exact
    // moment.
    private static let fallbackOrigin = "https://gallery.xenusanimations.studio"

    private let defaults = UserDefaults.standard

    /// Manual override, e.g. "http://127.0.0.1:8788" for local development.
    /// Empty means "auto-discover via live-config.json".
    var manualOverride: String {
        get { defaults.string(forKey: Self.overrideKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.overrideKey) }
    }

    private var cachedOrigin: String {
        get { defaults.string(forKey: Self.cachedKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.cachedKey) }
    }

    /// cachedOrigin, or the hardcoded fallback if nothing's ever been
    /// cached -- see fallbackOrigin's doc comment.
    private var cachedOrDefaultOrigin: String {
        let cached = cachedOrigin
        return cached.isEmpty ? Self.fallbackOrigin : cached
    }

    /// Best-known origin right now, without making a network call.
    /// True once a backend address has been saved (or set manually), so
    /// app launch can use it right away and refresh live-config in the
    /// background instead of waiting on GitHub Pages first.
    var hasKnownOrigin: Bool {
        !manualOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !cachedOrigin.isEmpty
    }

    var currentOrigin: String {
        let override = manualOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return normalizeOrigin(override) }
        return cachedOrDefaultOrigin
    }

    /// Refreshes from live-config.json (ignored if a manual override is set)
    /// and returns the resolved origin.
    @discardableResult
    func refresh() async -> String {
        let override = manualOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return normalizeOrigin(override) }
        do {
            var request = URLRequest(url: Self.liveConfigURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: request)
            let config = try JSONDecoder().decode(LiveConfigPayload.self, from: data)
            let origin = normalizeOrigin(config.gallery_url ?? config.api_url ?? "")
            if !origin.isEmpty {
                cachedOrigin = origin
                return origin
            }
        } catch {
            // Network error, live-config.json unreachable, or the GitHub
            // Pages host it's served from being down -- fall back to
            // whatever we last cached, or the hardcoded default if this is
            // the very first launch and nothing's cached yet.
        }
        return cachedOrDefaultOrigin
    }

    private func normalizeOrigin(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

private struct LiveConfigPayload: Decodable {
    let gallery_url: String?
    let api_url: String?
}
