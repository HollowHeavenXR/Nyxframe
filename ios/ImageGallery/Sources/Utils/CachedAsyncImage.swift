import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Memory tier of the image cache. `NSCache` is thread-safe, so this is
/// read synchronously from anywhere -- in particular from
/// `CachedAsyncImage.init`, so a card scrolling back into view shows its
/// image on the very first frame instead of flashing the placeholder while
/// an actor hop completes. Bounded by decoded bytes, not image count: a
/// 1920px detail preview decodes to ~8MB, so the old 300-image count limit
/// could hold well over a gigabyte.
final class DecodedImageMemoryCache: @unchecked Sendable {
    static let shared = DecodedImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        #if os(tvOS)
        cache.totalCostLimit = 200 * 1024 * 1024
        #else
        cache.totalCostLimit = 150 * 1024 * 1024
        #endif
        cache.countLimit = 500
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
    }

    private static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}

/// Disk tier: Caches/ImageCache, one file per URL (SHA-256 of the URL as
/// the name -- `String.hashValue` is randomized per process, so it can't
/// survive a relaunch). Plain static functions so every read/write runs on
/// whatever background task calls them, never on the `ImageCache` actor.
enum ImageDiskStore {
    /// Oldest-first eviction once the disk cache holds more than this many
    /// files -- mirrors web's "drop the oldest third" approach; thumbnails
    /// are small and roughly uniform, so a file count is a good enough proxy
    /// for a byte budget.
    static let maxEntries = 1200

    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func path(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hex)
    }

    static func pruneIfNeeded() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard entries.count > maxEntries else { return }
        let withDates = entries.map { fileUrl -> (URL, Date) in
            let date = (try? fileUrl.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (fileUrl, date)
        }
        let sorted = withDates.sorted { $0.1 < $1.1 }
        let removeCount = (sorted.count - maxEntries) + sorted.count / 4
        for (fileUrl, _) in sorted.prefix(removeCount) {
            try? FileManager.default.removeItem(at: fileUrl)
        }
    }
}

/// Turns downloaded bytes into a display-ready image off the main thread.
///
/// `UIImage(data:)` alone is lazy: the actual JPEG/WEBP decode happened
/// the first time the image was drawn -- on the main thread, mid-scroll,
/// which is where feed and TV-grid scrolling hitched. `preparingForDisplay()`
/// does that decode here instead. Images larger than any screen (originals
/// shown in the slideshow and full-screen views can be 4K+, ~40MB decoded)
/// are downsampled while decoding, so they never cost more memory than the
/// screen can actually show.
enum ImageDecoding {
    #if os(tvOS)
    static let maxPixelSize: CGFloat = 3840
    #else
    static let maxPixelSize: CGFloat = 2732
    #endif

    static func decode(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           CGFloat(max(width, height)) > maxPixelSize {
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as [CFString: Any] as CFDictionary
            if let downsampled = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
                return UIImage(cgImage: downsampled)
            }
        }
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

/// Shared image loader backing `CachedAsyncImage` below: memory tier
/// (`DecodedImageMemoryCache`), disk tier (`ImageDiskStore`, survives a
/// relaunch) and the network. An `actor` only for the in-flight map, so two
/// views asking for the same brand-new URL at once share one download and
/// one decode. All file I/O and decoding run in detached tasks, never on
/// the actor itself -- they used to, which made every image load in the
/// app queue up behind whichever disk read or decode was in progress.
actor ImageCache {
    static let shared = ImageCache()

    /// Images get their own session: no URLCache (the disk tier above
    /// already keeps every image, so URLSession's cache only stored a
    /// second copy), several connections per host for a screenful of
    /// thumbnails, and no waiting for connectivity -- a placeholder is
    /// better than a cell that spins indefinitely.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private var inFlight: [URL: Task<UIImage, Error>] = [:]
    private var storesSinceLastPrune = 0

    private init() {}

    /// Synchronous memory-only lookup (no disk, no network).
    nonisolated func memoryImage(for url: URL) -> UIImage? {
        DecodedImageMemoryCache.shared.image(for: url)
    }

    /// Memory, then disk. Never touches the network.
    nonisolated func image(for url: URL) async -> UIImage? {
        if let hit = DecodedImageMemoryCache.shared.image(for: url) { return hit }
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: ImageDiskStore.path(for: url)),
                  let image = ImageDecoding.decode(data) else { return nil }
            DecodedImageMemoryCache.shared.store(image, for: url)
            return image
        }.value
    }

    private func noteDiskStore() {
        storesSinceLastPrune += 1
        guard storesSinceLastPrune >= 50 else { return }
        storesSinceLastPrune = 0
        Task.detached(priority: .background) { ImageDiskStore.pruneIfNeeded() }
    }

    /// Memory, then disk, then network -- coalescing concurrent callers for
    /// the same URL onto one load.
    func loadImage(for url: URL) async throws -> UIImage {
        if let hit = DecodedImageMemoryCache.shared.image(for: url) { return hit }
        if let running = inFlight[url] {
            return try await running.value
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> UIImage in
            let diskURL = ImageDiskStore.path(for: url)
            if let data = try? Data(contentsOf: diskURL), let image = ImageDecoding.decode(data) {
                DecodedImageMemoryCache.shared.store(image, for: url)
                return image
            }
            let (data, response) = try await ImageCache.session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let image = ImageDecoding.decode(data) else {
                throw URLError(.cannotDecodeContentData)
            }
            DecodedImageMemoryCache.shared.store(image, for: url)
            try? data.write(to: diskURL, options: .atomic)
            await ImageCache.shared.noteDiskStore()
            return image
        }
        inFlight[url] = task
        do {
            let result = try await task.value
            inFlight[url] = nil
            return result
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

    /// Warms the cache for thumbnails about to scroll into view -- mirrors
    /// web's idle-scheduled `preloadMediaAssets`. Fire-and-forget, callable
    /// straight from a `@MainActor` view model, capped at three concurrent
    /// loads so it never meaningfully competes with on-screen images.
    nonisolated func preload(urls: [URL]) {
        let pending = urls.filter { DecodedImageMemoryCache.shared.image(for: $0) == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                func launchNext() {
                    guard let url = iterator.next() else { return }
                    group.addTask { _ = try? await ImageCache.shared.loadImage(for: url) }
                }
                for _ in 0..<min(3, pending.count) { launchNext() }
                for await _ in group { launchNext() }
            }
        }
    }
}

/// Identifies the media a `CachedAsyncImage` is loading, purely for the
/// optional load-diagnostics beacon below -- mirrors the `diagnostics={{
/// mediaId, mediaKind, context }}` prop web's `ResilientImage` (ui.jsx)
/// takes at its highest-value call sites (feed cards, media detail,
/// profile avatar) rather than every single image in the app.
struct ImageLoadDiagnosticsContext {
    var mediaId: Int
    var mediaKind: String
    var context: String
}

/// De-dupes repeat diagnostic beacons for an image already reported this
/// session -- a SwiftUI re-render of the same successful/failed image
/// (scrolling a cell off/on screen, an unrelated state change) would
/// otherwise re-fire the beacon every time `.task(id:)` re-runs. Oldest-
/// eviction once the cap is hit, not a wholesale clear (that bug was found
/// and fixed on the web side's equivalent `reportedMediaDiagnostics` Set --
/// no reason to reintroduce it here).
@MainActor
private final class ReportedImageDiagnostics {
    static let shared = ReportedImageDiagnostics()
    private var order: [String] = []
    private var seen: Set<String> = []
    private let cap = 800

    func markIfNew(_ signature: String) -> Bool {
        guard !seen.contains(signature) else { return false }
        seen.insert(signature)
        order.append(signature)
        if order.count > cap {
            let oldest = order.removeFirst()
            seen.remove(oldest)
        }
        return true
    }
}

/// Drop-in `AsyncImage` replacement with a real cache -- same
/// `url:content:` phase-based signature, so every existing call site
/// (`AsyncImage(url:) { phase in ... }`) only needs the type name changed,
/// nothing else.
///
/// Plain `AsyncImage` has no cache of its own: every layer SwiftUI creates
/// (a feed cell scrolling back on screen, a view rebuilding from unrelated
/// state changes, revisiting the same avatar/thumbnail somewhere else in
/// the app) re-fetches AND re-decodes the same bytes from scratch. That
/// repeated decode work is the actual cause of "scrolling the feed/detail
/// view feels laggy" reported live 2026-08-31 -- not a video/GPU problem,
/// a missing-cache problem. `ImageCache` above keeps already-decoded
/// `UIImage`s keyed by URL (memory + disk), so a repeat appearance is a
/// cache hit instead of a network round trip + decode, including across a
/// cold app relaunch.
@MainActor
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content
    private let diagnostics: ImageLoadDiagnosticsContext?

    @State private var phase: AsyncImagePhase

    init(url: URL?, diagnostics: ImageLoadDiagnosticsContext? = nil, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.diagnostics = diagnostics
        self.content = content
        // Already decoded in memory: show it on the first frame.
        if let url, let cached = DecodedImageMemoryCache.shared.image(for: url) {
            _phase = State(initialValue: .success(Image(uiImage: cached)))
        } else {
            _phase = State(initialValue: .empty)
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        if let cached = DecodedImageMemoryCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }
        phase = .empty
        do {
            let uiImage = try await ImageCache.shared.loadImage(for: url)
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: uiImage))
            reportLoad(outcome: "success")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
            reportLoad(outcome: "error")
        }
    }

    private func reportLoad(outcome: String) {
        guard let diagnostics, let url else { return }
        let signature = "\(diagnostics.mediaId)|\(diagnostics.context)|\(outcome)"
        guard ReportedImageDiagnostics.shared.markIfNew(signature) else { return }
        DiagnosticsReporter.reportMediaLoad(
            mediaId: diagnostics.mediaId, mediaKind: diagnostics.mediaKind,
            context: diagnostics.context, outcome: outcome, selectedSource: url.lastPathComponent
        )
    }
}
