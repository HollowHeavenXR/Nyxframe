import AVFoundation
import CoreMedia
import Foundation

/// Owns a single `AVPlayer` for one media item so the inline viewer
/// (`MediaDetailView`) and the fullscreen viewer (`FullScreenMediaView`) can
/// share the exact same playback session instead of each spinning up its own
/// `AuthenticatedVideoPlayer`/`AVPlayer` — previously the fullscreen button
/// created a second, fully independent player, leaving the original one
/// silently still playing behind it (no controls reached it, and it kept
/// running after the fullscreen sheet was dismissed).
@MainActor
final class VideoPlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?
    /// Non-nil while the "we picked up where you left off" chip should be
    /// showing -- see `AuthenticatedVideoPlayer`. Set once, on the first
    /// load of a session; a quality switch also restores a position but
    /// that's the viewer's own current position, not a resume, and
    /// announcing it would be noise.
    @Published private(set) var resumedFrom: Double?

    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var retryAttempt = 0
    private static let maxRetries = 2
    private var preflightTask: Task<Void, Never>?
    /// Playlist URLs whose preflight returned 200 this app session.
    private static var readyPlaylists = Set<URL>()

    /// Set (and playback restarted) whenever the quality selector picks a
    /// different rendition -- the URL, not the player, is the source of truth.
    private(set) var url: URL
    /// What the readiness preflight below should poll, when that isn't
    /// the playback URL itself.
    ///
    /// With captions available the player is handed a MASTER playlist
    /// (the only way AVPlayer can receive subtitles -- see
    /// MediaDetailView.videoQualityURL), and a master is generated
    /// instantly from a template: it answers 200 whether or not the
    /// rendition underneath it has a single segment encoded yet. Polling
    /// it would therefore always succeed immediately and hand AVPlayer a
    /// manifest pointing at a variant that still 503s -- silently
    /// reintroducing exactly the indefinite stall the preflight exists to
    /// prevent. So the caller passes the variant playlist here and the
    /// wait happens against the document that actually reports progress.
    private(set) var preflightURL: URL?
    private let mediaId: Int
    /// Reported with the playback telemetry on teardown. Previously
    /// hard-coded to nil here while web reported it on every session, so
    /// every iOS row in the telemetry table was missing the one dimension
    /// that says which rendition the numbers describe.
    private var quality: String
    private let title: String
    private let author: String?
    private let artworkURL: URL?

    /// Where to seek once the item reaches `.readyToPlay`: a stored resume
    /// position on a fresh load, or the viewer's current position across a
    /// quality switch. Seeking before that point is silently dropped on an
    /// HLS asset, which is why this is deferred rather than applied at
    /// attach time.
    private var pendingSeek: Double?
    /// A session resumes at most once; a later quality switch must not
    /// re-apply a stale stored position on top of the live one.
    private var hasConsideredResume = false
    /// Plain mirrors of the current position/duration, maintained by the
    /// periodic observer. `deinit` needs them and cannot touch
    /// MainActor-isolated state -- same constraint (and same workaround)
    /// as `hadFatalError` below.
    private var lastKnownTime: Double = 0
    private var lastKnownDuration: Double = 0
    private var timeObserverToken: Any?
    /// Held as a plain property so the periodic observer can be detached
    /// in `deinit`, where the `@Published` `player` is unreachable.
    private var observedPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?

    // ─── Playback telemetry (reportMediaPlayback on deinit) ─────────────────
    // Mirrors VideoPlayer.jsx's playbackStatsRef -- accumulated for this
    // controller's whole lifetime (a quality switch via setURL keeps adding
    // to the same session rather than resetting it), fired once when this
    // controller is torn down (navigating away/closing the detail view),
    // same "component teardown = session end" moment web uses.
    private var loadStartedAt: CFAbsoluteTime?
    private var firstFrameMs: Int?
    private var stallCount = 0
    private var stallStartedAt: CFAbsoluteTime?
    private var stallTotalMs = 0
    private var hasPlayedOnce = false
    private var stallObserver: NSObjectProtocol?
    /// Plain (non-`@Published`) mirror of "did `errorMessage` end up set" --
    /// `deinit` can't read `errorMessage` itself: it's `@Published`, and a
    /// property wrapper's accessor is MainActor-isolated even though
    /// `deinit` itself is not (unlike a plain stored property, which
    /// `deinit` may read directly). Confirmed by CI: "main actor-isolated
    /// property 'errorMessage' can not be referenced from a nonisolated
    /// context" at exactly this read.
    private var hadFatalError = false

    init(
        url: URL,
        mediaId: Int,
        quality: String = "original",
        title: String = "Nyxframe video",
        author: String? = nil,
        artworkURL: URL? = nil,
        preflightURL: URL? = nil
    ) {
        self.url = url
        self.preflightURL = preflightURL
        self.mediaId = mediaId
        self.quality = quality
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
    }

    func setURL(_ newURL: URL, quality newQuality: String? = nil, preflightURL newPreflightURL: URL? = nil) {
        if let newQuality { quality = newQuality }
        preflightURL = newPreflightURL
        guard newURL != url else { return }
        let wasPlaying = player?.timeControlStatus == .playing
        // Carry the position across the switch. Without this, picking a
        // different rendition restarted the video from zero -- web has
        // preserved it since the quality menu existed (VideoPlayer.jsx's
        // `pendingRestoreRef`), and losing your place is a much bigger
        // deal than the rendition you were changing.
        let position = player?.currentTime().seconds ?? 0
        url = newURL
        retryAttempt = 0
        errorMessage = nil
        hadFatalError = false
        teardownPlayerObservers()
        player = nil
        pendingSeek = (position.isFinite && position > 1) ? position : nil
        startPlayback(autoplay: wasPlaying)
    }

    func startIfNeeded() {
        guard player == nil, errorMessage == nil else { return }
        startPlayback(autoplay: true)
    }

    func pause() {
        player?.pause()
    }

    func retry() {
        retryAttempt = 0
        errorMessage = nil
        hadFatalError = false
        startPlayback(autoplay: true)
    }

    /// The undo half of auto-resume: jump back to the top and forget the
    /// stored position, so the next visit starts clean too. Mirrors the
    /// web player's "Start over" chip button.
    func startOver() {
        resumedFrom = nil
        pendingSeek = nil
        PlaybackPreferences.clearResumePosition(mediaId: mediaId)
        lastKnownTime = 0
        player?.seek(to: .zero)
        player?.play()
    }

    func dismissResumeNotice() {
        resumedFrom = nil
    }

    private func startPlayback(autoplay: Bool) {
        teardownPlayerObservers()
        preflightTask?.cancel()
        // Resume where this device left off, considered once per session
        // so a later quality switch (which sets its own pendingSeek from
        // the live position) can't be overridden by a stale stored one.
        if !hasConsideredResume {
            hasConsideredResume = true
            if pendingSeek == nil, let stored = PlaybackPreferences.resumePosition(mediaId: mediaId) {
                pendingSeek = stored
                resumedFrom = stored
            }
        }
        // Time-to-first-frame only means something for the very first load
        // of a playback session -- setURL's own quality-switch path (see
        // its doc comment) restarts playback too, but that's a rendition
        // change mid-session, not a fresh "how long until video appears".
        if loadStartedAt == nil { loadStartedAt = CFAbsoluteTimeGetCurrent() }
        var headers: [String: String] = [:]
        if let token = GalleryAPIClient.shared.authToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        // The HLS playlist route 503s with "still starting up" while this
        // quality's variant is mid-transcode server-side (routes.lua's
        // serve_hls_playlist) -- completely routine right after picking a
        // quality that hasn't been requested yet. hls.js/Safari on web
        // already retry that transparently (see VideoPlayer.jsx), but
        // AVPlayer has no equivalent visibility: a non-2xx HTTP status on
        // the playlist fetch surfaces through AVFoundationErrorDomain, not
        // NSURLErrorDomain, so isTransientNetworkError below never
        // recognized it as retryable and the player just failed permanently
        // with an opaque "resource unavailable" -- on literally the very
        // first watch of any quality, not something rare. Preflight the
        // playlist with a plain URLSession request and retry through a 503
        // BEFORE ever handing the URL to AVPlayer, so by the time AVPlayer
        // sees it, the playlist genuinely exists.
        //
        // BUGFIX 2026-08-31: this used to cap at 6 attempts with a fixed
        // 500ms*attempt backoff -- 10.5s of total budget before giving up
        // and handing AVPlayer a URL that was STILL 503ing, which then sat
        // there indefinitely (AVPlayer doesn't reliably flip an HLS asset's
        // .status to .failed just because its playlist 503s -- it can just
        // stall with no error and no video, exactly the reported "the
        // player never succeeds to play" symptom). A cold transcode
        // routinely takes far longer than 10.5s (confirmed server-side this
        // same day: 30-85s even on the now-GPU-accelerated path, and
        // several minutes were observed before that) -- the server was
        // never actually failing, the client just stopped asking before it
        // finished. That's also why switching quality "fixed" it: the
        // server-side encode keeps running regardless of whether the app
        // is still polling, so by the time a quality switch fires a fresh
        // preflight, enough real time has usually passed for it to already
        // be ready. Now honors the server's own Retry-After header
        // (present on every 503 this route can return -- "still starting
        // up" says 3s, "busy" 5s, "gpu unavailable" 15s) instead of a fixed
        // schedule, and retries against a wall-clock deadline instead of an
        // attempt count -- 3 minutes, comfortably past every real cold-start
        // time observed, matching the order of magnitude of the web
        // player's own retry budget (hls.js: 40 retries at up to 3s backoff
        // each, ~112s) rather than inventing a shorter one for iOS alone.
        // A playlist that already answered 200 this session (replaying a
        // video, coming back to it, switching back to a quality) is still
        // there -- skip the extra round trip through the tunnel and start
        // AVPlayer right away.
        if Self.readyPlaylists.contains(preflightURL ?? url) {
            attachPlayer(headers: headers, autoplay: autoplay)
            return
        }
        // A plain file (direct play, see MediaItem.directPlay) has no
        // "still transcoding" state to wait out, and probing it with a GET
        // would download the whole video. Hand it straight to AVPlayer.
        if !(preflightURL ?? url).path.hasSuffix(".m3u8") {
            attachPlayer(headers: headers, autoplay: autoplay)
            return
        }
        preflightTask = Task { [weak self] in
            guard let self else { return }
            let probeURL = preflightURL ?? url
            var probeReady = false
            var request = URLRequest(url: probeURL)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

            let deadline = Date().addingTimeInterval(180)
            var resolvedURL: URL?
            while !Task.isCancelled {
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 200
                    if status == 503 && Date() < deadline {
                        let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 3
                        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        continue
                    }
                    // A busy non-"original" quality gets a 302 to the
                    // original rendition server-side (routes.lua's
                    // serve_hls_playlist) -- URLSession follows it
                    // transparently here, but AVFoundation's own header
                    // propagation across an HTTP redirect is unreliable
                    // (the same limitation routes.lua's playlist rewriting
                    // already works around for segment requests -- see its
                    // "relying on AVURLAssetHTTPHeaderFieldsKey propagating"
                    // comment). Hand AVPlayer the already-resolved URL
                    // directly instead of the pre-redirect one, so it never
                    // has to replay that redirect (and its auth header)
                    // itself -- matters for private/adult-gated videos,
                    // where the redirect target needs the same Bearer token
                    // the original request carried.
                    // Only adopt the resolved URL when the probe WAS the
                    // playback URL. When they differ, this resolved a
                    // variant playlist and handing it to AVPlayer would
                    // throw away the master (and with it the subtitles).
                    if probeURL == self.url { resolvedURL = http?.url }
                    // Remember only a direct 200 (not a redirect to another
                    // rendition because this one was busy).
                    probeReady = status == 200 && (http?.url == nil || http?.url == probeURL)
                    break
                } catch {
                    break // Let AVPlayer's own load surface the real error for anything else.
                }
            }
            guard !Task.isCancelled else { return }
            let markReady = probeReady
            await MainActor.run {
                if markReady { Self.readyPlaylists.insert(probeURL) }
                if let resolvedURL, resolvedURL != self.url {
                    self.url = resolvedURL
                }
                self.attachPlayer(headers: headers, autoplay: autoplay)
            }
        }
    }

    private func attachPlayer(headers: [String: String], autoplay: Bool) {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        // The same reasoning as the web player's raised hls.js
        // `maxBufferLength`: a cold rendition is often being encoded
        // barely ahead of playback, so the default (AVPlayer picks its
        // own, typically a handful of seconds) leaves almost no runway
        // and turns one slow segment fetch into a visible stall. Buffering
        // further ahead absorbs it. Not unlimited -- a large value here
        // costs memory and up-front bandwidth on a rendition the viewer
        // may abandon after ten seconds.
        item.preferredForwardBufferDuration = 90
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let failure = observedItem.error
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .failed:
                    self.handleFailure(failure)
                case .readyToPlay:
                    // Seeks issued before this point are silently dropped
                    // on an HLS asset, which is why both the resume
                    // position and the quality-switch position wait here
                    // rather than being applied at attach time.
                    self.applyPendingSeek()
                default:
                    break
                }
            }
        }
        // Watched to the end: nothing left to resume, and keeping the
        // entry would make the next visit open with a pointless "resumed
        // at 9:52" of a 10:00 video.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                PlaybackPreferences.clearResumePosition(mediaId: self.mediaId)
                self.lastKnownTime = 0
                NotificationCenter.default.post(name: .nyxframeVideoReachedEnd, object: nil, userInfo: ["mediaId": self.mediaId])
            }
        }
        let newPlayer = AVPlayer(playerItem: item)
        // BackgroundMusicService observes this to duck/restore its own
        // volume -- rate (not play()/pause() call sites) so this also
        // catches play/pause triggered by AVKit's native transport controls,
        // not just our own startPlayback()/pause() methods.
        rateObservation = newPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            NotificationCenter.default.post(name: .nyxframeVideoPlaybackChanged, object: nil, userInfo: ["playing": player.rate > 0])
            // Keep the lock screen's play/pause glyph honest, including
            // when the change came from AVKit's own transport controls or
            // from a stall -- the periodic observer alone would leave it
            // wrong for up to five seconds.
            let rate = player.rate
            let elapsed = player.currentTime().seconds
            DispatchQueue.main.async {
                guard let self, elapsed.isFinite else { return }
                NowPlayingCenter.shared.update(owner: self, elapsed: elapsed, duration: self.lastKnownDuration, rate: rate)
            }
            guard player.rate > 0, let self else { return }
            DispatchQueue.main.async {
                guard !self.hasPlayedOnce else { return }
                self.hasPlayedOnce = true
                if self.firstFrameMs == nil, let startedAt = self.loadStartedAt {
                    self.firstFrameMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                }
            }
        }
        // isPlaybackLikelyToKeepUp flips false->true exactly at the point
        // playback resumes smoothly after a rebuffer -- paired with the
        // .AVPlayerItemPlaybackStalled notification (which fires at the
        // START of a stall) to get both a count and a total duration,
        // mirroring VideoPlayer.jsx's onWaiting/onCanPlay stall tracking.
        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.isPlaybackLikelyToKeepUp else { return }
            DispatchQueue.main.async {
                guard let self, let startedAt = self.stallStartedAt else { return }
                self.stallTotalMs += Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                self.stallStartedAt = nil
            }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            // `queue: .main` only guarantees which thread this runs on, not
            // MainActor isolation as the compiler sees it (this closure's
            // parameter type is `@Sendable`) -- hop explicitly, same as
            // every other cross-actor callback in this file.
            DispatchQueue.main.async {
                guard let self else { return }
                self.stallCount += 1
                if self.stallStartedAt == nil { self.stallStartedAt = CFAbsoluteTimeGetCurrent() }
            }
        }
        player = newPlayer
        observedPlayer = newPlayer
        attachTimeObserver(to: newPlayer)
        NowPlayingCenter.shared.begin(
            owner: self,
            title: title,
            artist: author,
            artworkURL: artworkURL,
            handlers: NowPlayingCenter.Handlers(
                play: { [weak self] in self?.player?.play() },
                pause: { [weak self] in self?.player?.pause() },
                seek: { [weak self] position in
                    self?.player?.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                },
                skip: { [weak self] offset in
                    guard let player = self?.player else { return }
                    let target = max(0, player.currentTime().seconds + offset)
                    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                }
            )
        )
        if autoplay { newPlayer.play() }
    }

    private func applyPendingSeek() {
        guard let target = pendingSeek, let player else { return }
        pendingSeek = nil
        // Default tolerances on purpose: an exact seek on HLS has to fetch
        // and decode from the preceding keyframe, and a second of slop is
        // invisible next to the wait it saves.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Five seconds: frequent enough that navigating away loses at most
    /// that much of the viewer's place, rare enough that the UserDefaults
    /// write behind it is inconsequential.
    private func attachTimeObserver(to player: AVPlayer) {
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main
        ) { [weak self] time in
            // `queue: .main` is a thread guarantee, not MainActor
            // isolation as the compiler sees it -- hop explicitly, same as
            // every other cross-actor callback in this file.
            let seconds = time.seconds
            DispatchQueue.main.async { self?.handleTimeUpdate(seconds: seconds) }
        }
    }

    private func detachTimeObserver() {
        if let timeObserverToken, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        observedPlayer = nil
    }

    private func handleTimeUpdate(seconds: Double) {
        guard seconds.isFinite, let player else { return }
        lastKnownTime = seconds
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite, duration > 0 { lastKnownDuration = duration }
        PlaybackPreferences.saveResumePosition(mediaId: mediaId, time: seconds, duration: lastKnownDuration)
        NowPlayingCenter.shared.update(owner: self, elapsed: seconds, duration: lastKnownDuration, rate: player.rate)
    }

    private func teardownPlayerObservers() {
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        likelyToKeepUpObservation?.invalidate()
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        stallObserver = nil
        endObserver = nil
        detachTimeObserver()
    }

    private func handleFailure(_ error: Error?) {
        guard isTransientNetworkError(error), retryAttempt < Self.maxRetries else {
            errorMessage = error?.localizedDescription ?? "Unknown error."
            hadFatalError = true
            return
        }
        retryAttempt += 1
        player = nil
        let delay = 0.5 * Double(retryAttempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startPlayback(autoplay: true)
        }
    }

    private func isTransientNetworkError(_ error: Error?) -> Bool {
        guard let error else { return false }
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSURLErrorDomain {
                switch candidate.code {
                case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                     NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                     NSURLErrorSecureConnectionFailed:
                    return true
                default:
                    return false
                }
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    deinit {
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        likelyToKeepUpObservation?.invalidate()
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserverToken, let observedPlayer { observedPlayer.removeTimeObserver(timeObserverToken) }
        preflightTask?.cancel()

        // Navigating away mid-video is the most common way a session
        // ends, and the periodic save can be up to five seconds stale by
        // then -- flush the last known position so "resume" lands where
        // the viewer actually stopped. Reads the plain mirrors, not the
        // player: `deinit` is nonisolated and may not touch the
        // MainActor-isolated `@Published` properties.
        PlaybackPreferences.saveResumePosition(mediaId: mediaId, time: lastKnownTime, duration: lastKnownDuration)

        // Hand the lock screen back. Keyed by identity rather than
        // clearing unconditionally: this controller can outlive its
        // usefulness and be deallocated *after* the next video's
        // controller has already taken the session over, and wiping that
        // one's metadata would leave the lock screen blank mid-playback.
        let ownerId = ObjectIdentifier(self)
        Task { @MainActor in NowPlayingCenter.shared.end(ownerId: ownerId) }

        // Unconditional, not conditioned on prior playback state -- mirrors
        // web's identical unmount-safety comment on VideoPlayer.jsx: this
        // controller being deallocated mid-playback (navigating away) would
        // otherwise leave BackgroundMusicService permanently ducked with no
        // matching "stopped" rate change ever coming. A redundant post when
        // nothing was playing is a harmless no-op fade to the same volume.
        NotificationCenter.default.post(name: .nyxframeVideoPlaybackChanged, object: nil, userInfo: ["playing": false, "closed": true])

        // Playback telemetry -- fired once here (controller teardown = the
        // end of this playback session), same moment VideoPlayer.jsx's own
        // unmount cleanup reports its accumulated stats.
        guard loadStartedAt != nil else { return }
        DiagnosticsReporter.reportMediaPlayback(
            mediaId: mediaId,
            outcome: hadFatalError ? "error" : hasPlayedOnce ? "played" : "abandoned",
            quality: quality, timeToFirstFrameMs: firstFrameMs,
            stallCount: stallCount, stallTotalMs: stallTotalMs, retryCount: retryAttempt
        )
    }
}
