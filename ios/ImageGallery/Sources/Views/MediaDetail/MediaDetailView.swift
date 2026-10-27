import SwiftUI
import UIKit

struct MediaDetailView: View {
    @StateObject private var viewModel: MediaDetailViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var showingReport = false
    @State private var showingEdit = false
    @State private var showingAgeVerification = false
    @State private var showingFullScreen = false
    @State private var originalURL: URL?
    @State private var showingOriginalInApp = false
    @State private var videoController: VideoPlayerController?
    /// Seeded from this device's own last explicit pick rather than
    /// always "original": someone on a capped connection who chooses 480p
    /// means it for their connection, not for one post. Web does the same
    /// (MediaDetailPage's `getPlayerPref("quality", ...)`).
    @State private var videoQuality = PlaybackPreferences.quality
    /// True once the backend reports a generated caption track for this
    /// post, which changes WHICH manifest the player is pointed at -- see
    /// `videoQualityURL`.
    @State private var hasCaptions = false

    private static let qualityOptions: [(String, String)] = [
        ("original", "Original"),
        ("1080p", "1080p HD"),
        ("720p", "720p"),
        ("480p", "480p"),
        ("144p", "144p"),
    ]

    init(mediaId: Int) {
        _viewModel = StateObject(wrappedValue: MediaDetailViewModel(mediaId: mediaId))
    }

    @Environment(\.nyxTabIsActive) private var tabIsActive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let media = viewModel.media {
                    mediaViewer(media)
                        .padding(.horizontal, 12)

                    infoPanel(media)
                    commentsPanel
                    similarSection
                } else if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else if let errorMessage = viewModel.errorMessage {
                    InlineErrorView(message: errorMessage) { await viewModel.load() }
                        .padding(.top, 40)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(ambientBackdrop)
        .hidesDock()
        .navigationTitle(viewModel.media?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
            setUpVideoControllerIfNeeded()
            if let media = viewModel.media { await loadPlaybackExtras(for: media) }
        }
        .task { viewModel.startViewingHeartbeat() }
        .sheet(isPresented: $showingReport) { ReportSheet(viewModel: viewModel) }
        .sheet(isPresented: $showingEdit) { MediaEditSheet(viewModel: viewModel) }
        // Owner-only, and driven off the loaded media rather than a passed-in
        // flag so it stays correct when the view model reloads the post.
        .toolbar {
            if let media = viewModel.media,
               let viewerId = session.currentUser?.id,
               media.userId == viewerId {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil") }
                }
            }
        }
        .sheet(isPresented: $showingAgeVerification, onDismiss: { Task { await viewModel.load() } }) { AgeVerificationView() }
        // isPresented + a separately-stored URL, not .sheet(item:) -- URL
        // doesn't conform to Identifiable, and this matches the same
        // pattern StudioView/CollectionsListView already use for their own
        // "optional URL drives a sheet" cases (showingDownloadShare +
        // downloadURL).
        .sheet(isPresented: $showingOriginalInApp) {
            if let originalURL { InAppSafariView(url: originalURL) }
        }
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let media = viewModel.media {
                FullScreenMediaView(
                    media: media,
                    // "Play all": images only (see FullScreenMediaView's
                    // header comment for why video stays single-item) --
                    // the current post plus its "More like this" rail is
                    // the one ordered list MediaDetailView has on hand,
                    // there being no shared lightbox/grid-with-index
                    // concept on iOS the way web's Lightbox has.
                    slideshowItems: media.isVideo ? [] : ([media] + viewModel.similar.filter { !$0.isVideo }),
                    videoController: videoController,
                    qualityOptions: Self.qualityOptions,
                    videoQuality: videoQuality,
                    onQualityChange: { changeQuality($0, media: media) }
                )
            }
        }
        .onChange(of: viewModel.media?.id) { _ in
            videoQuality = PlaybackPreferences.quality
            hasCaptions = false
            videoController = nil
            setUpVideoControllerIfNeeded()
            if let media = viewModel.media {
                Task { await loadPlaybackExtras(for: media) }
            }
        }
        // The shell keeps other tabs alive without ever calling
        // onDisappear on them, so leaving this tab has to pause playback
        // explicitly -- otherwise a video keeps playing, with sound, from
        // a tab nobody is looking at.
        .onChange(of: tabIsActive) { isActive in
            if !isActive {
                videoController?.pause()
                viewModel.stopViewingHeartbeat()
            } else {
                viewModel.startViewingHeartbeat()
            }
        }
        .onAppear { setUpVideoControllerIfNeeded() }
        .onDisappear {
            videoController?.pause()
            viewModel.stopViewingHeartbeat()
        }
    }

    // MARK: Nocturne layout

    /// "Ambient mode": the post's own thumbnail, blown up and blurred into
    /// a glow behind the page, so every post tints the sky it sits on.
    private var ambientBackdrop: some View {
        ZStack(alignment: .top) {
            NyxBackdrop(showsStars: false)
            if let urlString = viewModel.media?.thumbUrl, viewModel.media?.locked != true, let url = URL(string: urlString) {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 560)
                .frame(maxWidth: .infinity)
                .clipped()
                .blur(radius: 70)
                .opacity(0.55)
                .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }

    private func infoPanel(_ media: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow = metaLine(media) {
                    Text(eyebrow.uppercased())
                        .font(Nyx.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(Color.accentColor)
                }
                Text(media.title?.nilIfEmpty ?? "Untitled")
                    .font(Nyx.display(26))
                    .fixedSize(horizontal: false, vertical: true)
            }

            UploaderRow(media: media)

            // Only once there are at least 2 (the viewer's own heartbeat
            // always counts as 1, so "viewing now: 1" would just describe
            // the viewer to themselves) -- matches web's `viewingNow >= 2`
            // gate exactly.
            if let viewingNow = viewModel.viewingNow, viewingNow >= 2 {
                Label("\(viewingNow) people viewing this now", systemImage: "eye")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Nyx.mist)
            }

            MediaActionBar(
                media: media,
                isTogglingLike: viewModel.isTogglingLike,
                isTogglingBookmark: viewModel.isTogglingBookmark,
                onLike: { Task { await viewModel.toggleLike() } },
                onBookmark: { Task { await viewModel.toggleBookmark() } },
                onReport: { showingReport = true },
                onOpenOriginal: { openOriginal(media) },
                onDownload: { viewModel.downloadToDevice() }
            )

            if let description = media.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let tags = media.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            ReactionTray(reactions: viewModel.reactions) { emoji in
                Task { await viewModel.react(emoji: emoji) }
            }

            if session.currentUser != nil {
                PersonalTagsSection(viewModel: viewModel)
            }

            // Owner-only, same gate as the Edit toolbar button above.
            if let viewerId = session.currentUser?.id, media.userId == viewerId {
                DisclosureGroup("Edit history") {
                    MediaEditHistoryView(viewModel: viewModel)
                        .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(18)
        .nyxGlass(radius: Nyx.Radius.panel)
        .padding(.horizontal, 12)
    }

    private var commentsPanel: some View {
        CommentsSection(viewModel: viewModel)
            .padding(18)
            .nyxGlass(radius: Nyx.Radius.panel)
            .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var similarSection: some View {
        if !viewModel.similar.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                NyxSectionHeader(eyebrow: "Constellation", title: "More like this") {
                    // Reuses the already-stored perceptual hash rather than
                    // re-uploading this post's own image -- image posts
                    // only, same restriction the backend's visual-similar
                    // route enforces (videos have no fingerprint).
                    if viewModel.media?.isVideo == false {
                        NavigationLink("Find visually similar") { VisualSearchView(seedMediaId: viewModel.mediaId) }
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                    }
                }
                SimilarMediaRail(items: viewModel.similar)
            }
            .padding(.top, 6)
        }
    }

    /// "Wallpapers · 3 days ago", from whichever of the two is known.
    private func metaLine(_ media: MediaItem) -> String? {
        var parts: [String] = []
        if let category = media.categoryName?.nilIfEmpty { parts.append(category) }
        if media.createdAt != nil { parts.append(DateFormatting.relative(media.createdAt)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Real HLS instead of a single Range-served file: AVPlayer has native
    /// HLS support, so this is purely a URL swap. "original" points straight
    /// at that one rendition's own playlist (a fast `-c copy` remux, no
    /// re-encode -- see routes.lua's ensure_hls_variant), NOT the master
    /// playlist -- previously it did, and that's very likely why "original
    /// quality just loads forever" was reported: master.m3u8 hands AVPlayer
    /// genuine ABR across all 4 transcoded renditions, and on a cold
    /// connection/cache, AVPlayer has no bandwidth history to negotiate
    /// with, so it can end up waiting on a rendition that isn't ready yet
    /// (the backend's serve_hls_playlist 503s "still starting up" for up to
    /// 8s server-side while a transcode is in flight, and there's nothing
    /// here retrying that the way the native/hls.js error paths in
    /// VideoPlayer.jsx do). The web app hit this exact problem and
    /// deliberately reverted away from master.m3u8 for "original" -- see
    /// videoQualityUrl's comment in utils/media.js -- this brings iOS in
    /// line with that already-proven fix instead of independently
    /// rediscovering it.
    private func videoQualityURL(_ media: MediaItem, quality: String) -> URL? {
        guard let urlString = media.url, var components = URLComponents(string: urlString) else { return nil }
        let accessToken = (components.queryItems ?? []).first { $0.name == "access" }?.value
        guard components.path.hasSuffix("/file") else { return nil }
        let base = String(components.path.dropLast("/file".count))
        let rendition = (quality == "original" || quality.isEmpty || quality == "high") ? "original" : quality
        // Direct play: the stored file itself for "original", when it's a
        // format AVPlayer plays as-is and there are no captions (captions
        // need a manifest -- see below).
        if rendition == "original", media.directPlay == true, !hasCaptions {
            return URL(string: urlString)
        }
        // With captions available, point at the per-quality MASTER rather
        // than the rendition playlist. AVPlayer cannot side-load a
        // subtitle file the way a browser can attach a <track> -- a
        // subtitle rendition declared in a manifest is the only route it
        // has -- and AVKit then surfaces its own caption button and
        // honours the system's Closed Captions accessibility setting for
        // free.
        //
        // This master wraps exactly ONE rendition (see
        // video_extras.serve_quality_master), so it changes nothing about
        // which video segments get fetched. That matters: the site-wide
        // master.m3u8 offers real ABR across the whole ladder, and
        // pointing iOS at THAT is what caused "original quality just
        // loads forever" and was reverted -- AVPlayer picks a level from
        // a bandwidth estimate it doesn't have yet on a cold connection.
        // The explicit quality the viewer chose stays exactly as it is.
        components.path = base + "/hls/\(rendition)/" + (hasCaptions ? "master.m3u8" : "playlist.m3u8")
        components.queryItems = accessToken.map { [URLQueryItem(name: "access", value: $0)] }
        return components.url
    }

    /// The rendition playlist for the same quality -- the document that
    /// actually 503s while a transcode is cold, which is what the
    /// controller's readiness preflight has to wait on. See
    /// `VideoPlayerController.preflightURL`.
    private func variantPlaylistURL(_ media: MediaItem, quality: String) -> URL? {
        guard hasCaptions else { return nil }
        guard let urlString = media.url, var components = URLComponents(string: urlString) else { return nil }
        let accessToken = (components.queryItems ?? []).first { $0.name == "access" }?.value
        guard components.path.hasSuffix("/file") else { return nil }
        let base = String(components.path.dropLast("/file".count))
        let rendition = (quality == "original" || quality.isEmpty || quality == "high") ? "original" : quality
        components.path = base + "/hls/\(rendition)/playlist.m3u8"
        components.queryItems = accessToken.map { [URLQueryItem(name: "access", value: $0)] }
        return components.url
    }

    /// Asks the backend whether this post has a caption track yet, and
    /// starts generating one if not. Cheap, and deliberately fire and
    /// forget: captions are a background nicety, so a failure here just
    /// means the player keeps the manifest it already has.
    private func loadPlaybackExtras(for media: MediaItem) async {
        guard media.isVideo, !hasCaptions else { return }
        guard let extras = try? await GalleryAPIClient.shared.playbackExtras(mediaId: media.id) else { return }
        guard extras.captions?.status == "ready" else { return }
        hasCaptions = true
        // Re-point the live player at the captioned manifest. setURL
        // carries the current position across (see VideoPlayerController),
        // so this is invisible beyond the caption button appearing.
        if let controller = videoController, let url = videoQualityURL(media, quality: videoQuality) {
            controller.setURL(url, quality: videoQuality, preflightURL: variantPlaylistURL(media, quality: videoQuality))
        }
    }

    // open_original_in_new_tab -- web's literal "new tab" framing doesn't
    // map 1:1 to iOS (there's no tab to stay on), so the natural
    // equivalent is "leave the app" (launch system Safari) vs. "stay in
    // the app" (an embedded SFSafariViewController sheet). This is the
    // one iOS action MediaActionBar never had at all before this -- there
    // was no "Open Original" anywhere in the app, unlike web's
    // MediaActionPanel.
    private func openOriginal(_ media: MediaItem) {
        guard let urlString = media.url, let url = URL(string: urlString) else { return }
        if session.currentUser?.userSettings?.openOriginalInNewTab == true {
            UIApplication.shared.open(url)
        } else {
            originalURL = url
            showingOriginalInApp = true
        }
    }

    private func setUpVideoControllerIfNeeded() {
        guard videoController == nil, let media = viewModel.media, media.isVideo else { return }
        guard let url = videoQualityURL(media, quality: videoQuality) else { return }
        videoController = VideoPlayerController(
            url: url,
            mediaId: media.id,
            quality: videoQuality,
            title: media.title?.nilIfEmpty ?? "Nyxframe video",
            author: media.displayName ?? media.username,
            // Doubles as the lock screen's artwork. The thumbnail, not
            // the original: this is displayed at a few hundred points and
            // gets fetched on every video, so the multi-MB source would
            // be pure waste.
            artworkURL: media.thumbUrl.flatMap(URL.init(string:)),
            preflightURL: variantPlaylistURL(media, quality: videoQuality)
        )
    }

    private func changeQuality(_ quality: String, media: MediaItem) {
        guard quality != videoQuality else { return }
        videoQuality = quality
        // Every call here comes from the quality menu, i.e. is a
        // deliberate choice -- the player never picks a rendition for
        // itself on iOS the way web's codec fallback does, so there is no
        // automatic switch that could pollute this.
        PlaybackPreferences.quality = quality
        guard let controller = videoController, let url = videoQualityURL(media, quality: quality) else { return }
        controller.setURL(url, quality: quality, preflightURL: variantPlaylistURL(media, quality: quality))
    }

    private var qualityMenu: some View {
        VideoQualityMenu(options: Self.qualityOptions, current: videoQuality) { value in
            if let media = viewModel.media { changeQuality(value, media: media) }
        }
    }

    @ViewBuilder
    private func mediaViewer(_ media: MediaItem) -> some View {
        if media.locked == true {
            VStack(spacing: 14) {
                Image(systemName: "moon.haze.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("This 18+ post is veiled until you verify your age.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Nyx.mist)
                Button("Verify Age") { showingAgeVerification = true }
                    .buttonStyle(NyxPrimaryButtonStyle())
                    .frame(maxWidth: 220)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 260)
            .nyxGlass(radius: Nyx.Radius.hero)
        } else if media.isVideo, let player = videoController {
            AuthenticatedVideoPlayer(controller: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Nyx.Radius.panel, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        qualityMenu
                        expandButton
                    }
                    .padding(10)
                }
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 14)
        } else if let urlString = media.previewUrl?.nilIfEmpty ?? media.url, let url = URL(string: urlString) {
            // `previewUrl` is a server-resized/recompressed WEBP (capped at
            // 1920px), not the raw original `url` — this inline viewer is
            // capped in height anyway, so fetching the full multi-MB
            // original here just makes the first paint slow for no visible
            // benefit. `FullScreenMediaView` (reached via `expandButton`
            // below) still uses the true original for full quality once the
            // viewer explicitly asks for it.
            ZoomableAsyncImage(url: url, diagnostics: ImageLoadDiagnosticsContext(mediaId: media.id, mediaKind: media.mediaKind ?? "", context: "media-detail"))
                // An extreme portrait aspect ratio could otherwise stretch
                // to fill most of the screen — cap it so the rest of the
                // page stays reachable.
                .frame(maxHeight: 540)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Nyx.Radius.panel, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    expandButton.padding(10)
                }
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 14)
        }
    }

    private var expandButton: some View {
        NyxOrbButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "View fullscreen") {
            showingFullScreen = true
        }
        .foregroundStyle(.white)
    }
}
