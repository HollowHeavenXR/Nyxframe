import Foundation

/// TTL cache + in-flight request de-duplication for GET responses, applied
/// selectively via `GalleryAPIClient.requestJSONCached` -- mirrors web's
/// `cachedApiFetch`/`revalidateCache` (`frontend/src/api.js`) which the iOS
/// app had no equivalent of at all: every screen refetched fresh on every
/// appearance, even a feed the user had just left and come straight back
/// to. Deliberately simpler than web's version (no persisted storage tier,
/// no stale-while-revalidate) -- an in-memory-only, short-TTL cache already
/// covers the common case (revisiting a screen within a few seconds) with
/// far less risk of ever serving genuinely stale data.
actor APIResponseCache {
    static let shared = APIResponseCache()

    private struct Entry {
        let data: Data
        let expiresAt: Date
    }

    private var store: [String: Entry] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]

    private init() {}

    /// Returns cached bytes for `key` if still fresh; otherwise runs
    /// `fetch`, coalescing concurrent callers for the same key onto one
    /// underlying request (the same in-flight-task pattern as `ImageCache`).
    func data(for key: String, ttl: TimeInterval, fetch: @Sendable @escaping () async throws -> Data) async throws -> Data {
        if let entry = store[key], entry.expiresAt > Date() {
            return entry.data
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let task = Task<Data, Error> { try await fetch() }
        inFlight[key] = task
        do {
            let data = try await task.value
            inFlight[key] = nil
            store[key] = Entry(data: data, expiresAt: Date().addingTimeInterval(ttl))
            // Expired entries were never removed, so every page, search and
            // profile ever fetched stayed in memory for the app's lifetime.
            if store.count > 150 {
                let now = Date()
                store = store.filter { $0.value.expiresAt > now }
            }
            return data
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    /// Drops every cached entry whose key starts with `pathPrefix` (e.g.
    /// after a mutation that a short TTL alone wouldn't reflect quickly
    /// enough to feel instant, like a fresh upload not yet showing up in
    /// "my uploads"). Cache keys are built as `"<path>?<query>|<auth>"` in
    /// `GalleryAPIClient.requestJSONCached`, so a path-only prefix matches
    /// every query-param/auth-state variant of that endpoint.
    func invalidate(pathPrefix: String) {
        store = store.filter { !$0.key.hasPrefix(pathPrefix) }
    }
}
