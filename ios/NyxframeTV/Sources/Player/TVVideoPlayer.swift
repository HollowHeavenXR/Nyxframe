import AVKit
import SwiftUI

/// Builds the HLS URLs the backend serves for a video post. Same rules as
/// the iOS app's MediaDetailView.videoQualityURL: "original" points at that
/// one rendition's own playlist (never the site-wide ABR master, which
/// stalls on a cold connection), and once captions exist the per-quality
/// master is used instead, because a manifest-declared subtitle track is
/// the only way AVPlayer can show captions.
enum TVVideoURLs {
    static let qualities: [(String, String)] = [
        ("original", "Original"),
        ("1080p", "1080p HD"),
        ("720p", "720p"),
        ("480p", "480p"),
        ("144p", "144p"),
    ]

    static func playback(_ media: MediaItem, quality: String, captions: Bool) -> URL? {
        // Direct play: the stored file for "original" when it plays as-is
        // and there are no captions (those need a manifest).
        let isOriginal = quality.isEmpty || quality == "original" || quality == "high"
        if isOriginal, media.directPlay == true, !captions, let urlString = media.url {
            return URL(string: urlString)
        }
        return build(media, quality: quality, file: captions ? "master.m3u8" : "playlist.m3u8")
    }

    /// The rendition playlist -- what the controller's readiness preflight
    /// has to poll when the player itself is given the captioned master.
    static func preflight(_ media: MediaItem, quality: String, captions: Bool) -> URL? {
        captions ? build(media, quality: quality, file: "playlist.m3u8") : nil
    }

    private static func build(_ media: MediaItem, quality: String, file: String) -> URL? {
        guard let urlString = media.url, var components = URLComponents(string: urlString) else { return nil }
        let accessToken = (components.queryItems ?? []).first { $0.name == "access" }?.value
        guard components.path.hasSuffix("/file") else { return URL(string: urlString) }
        let base = String(components.path.dropLast("/file".count))
        let rendition = (quality.isEmpty || quality == "original" || quality == "high") ? "original" : quality
        components.path = base + "/hls/\(rendition)/\(file)"
        components.queryItems = accessToken.map { [URLQueryItem(name: "access", value: $0)] }
        return components.url
    }
}

/// Full-screen playback for one video post. Owns a shared
/// `VideoPlayerController` (retries a still-transcoding stream, resumes
/// where this TV left off, reports playback telemetry, and announces
/// play/end/close so the background music fades out and back in).
struct TVVideoPlayerScreen: View {
    let media: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var controller: VideoPlayerController?
    @State private var quality = PlaybackPreferences.quality
    @State private var hasCaptions = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller {
                TVPlayerHost(controller: controller, quality: quality) { newQuality in
                    changeQuality(newQuality)
                }
                .ignoresSafeArea()
                TVPlayerErrorOverlay(controller: controller)
            } else {
                TVMessageView(systemImage: "film", title: "This video can't be played", message: "Its stream address is missing.")
            }
        }
        .onAppear { setUp() }
        .onDisappear {
            controller?.pause()
            // Dropping the controller tears it down, which tells the
            // soundtrack the video was closed.
            controller = nil
        }
        .task { await loadCaptions() }
    }

    private func setUp() {
        guard controller == nil, let url = TVVideoURLs.playback(media, quality: quality, captions: hasCaptions) else { return }
        let newController = VideoPlayerController(
            url: url,
            mediaId: media.id,
            quality: quality,
            title: media.title?.nilIfEmpty ?? "Nyxframe video",
            author: media.displayName ?? media.username,
            artworkURL: media.thumbUrl.flatMap(URL.init(string:)),
            preflightURL: TVVideoURLs.preflight(media, quality: quality, captions: hasCaptions)
        )
        controller = newController
        newController.startIfNeeded()
    }

    private func changeQuality(_ newQuality: String) {
        guard newQuality != quality else { return }
        quality = newQuality
        PlaybackPreferences.quality = newQuality
        guard let url = TVVideoURLs.playback(media, quality: newQuality, captions: hasCaptions) else { return }
        controller?.setURL(url, quality: newQuality, preflightURL: TVVideoURLs.preflight(media, quality: newQuality, captions: hasCaptions))
    }

    /// Captions are generated in the background; once they exist the
    /// player is re-pointed at the captioned manifest (position kept).
    private func loadCaptions() async {
        guard let extras = try? await GalleryAPIClient.shared.playbackExtras(mediaId: media.id),
              extras.captions?.status == "ready", !hasCaptions else { return }
        hasCaptions = true
        guard let url = TVVideoURLs.playback(media, quality: quality, captions: true) else { return }
        controller?.setURL(url, quality: quality, preflightURL: TVVideoURLs.preflight(media, quality: quality, captions: true))
    }
}

private struct TVPlayerErrorOverlay: View {
    @ObservedObject var controller: VideoPlayerController

    var body: some View {
        if let message = controller.errorMessage {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 64))
                Text("Playback problem").font(.title2.bold())
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { controller.retry() }
            }
            .padding(60)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
        }
    }
}

/// AVPlayerViewController, the native tvOS player: Siri Remote scrubbing,
/// info/subtitle/audio panels, and a custom quality menu in its
/// transport bar.
private struct TVPlayerHost: UIViewControllerRepresentable {
    @ObservedObject var controller: VideoPlayerController
    let quality: String
    let onQuality: (String) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let viewController = AVPlayerViewController()
        viewController.player = controller.player
        viewController.transportBarCustomMenuItems = [qualityMenu()]
        return viewController
    }

    func updateUIViewController(_ viewController: AVPlayerViewController, context: Context) {
        if viewController.player !== controller.player {
            viewController.player = controller.player
            controller.player?.play()
        }
        viewController.transportBarCustomMenuItems = [qualityMenu()]
    }

    private func qualityMenu() -> UIMenu {
        let actions = TVVideoURLs.qualities.map { value, label in
            UIAction(title: label, state: value == quality ? .on : .off) { _ in onQuality(value) }
        }
        return UIMenu(title: "Quality", image: UIImage(systemName: "slider.horizontal.3"), options: [.singleSelection], children: actions)
    }
}
