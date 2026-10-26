import SwiftUI

struct MediaCard: View {
    let item: MediaItem
    /// Width / height. Masonry grids pass the tile's rhythm ratio (see
    /// `GridRhythm`); nil falls back to the viewer's `card_aspect_ratio`.
    var aspectRatio: CGFloat? = nil

    @EnvironmentObject private var session: SessionStore
    @Environment(\.nyxTabIsActive) private var tabIsActive
    @StateObject private var previewController = GridPreviewController()
    @State private var isOnScreen = false

    private var settings: UserSettings? { session.currentUser?.userSettings }

    // Mirrors media.jsx's `liveVideoPreview` gate exactly: video items only,
    // never a locked (age-gated, not-yet-verified) post, only when the
    // viewer has actually turned previews on, and only once this card is
    // actually on screen (LazyVGrid already defers instantiating off-screen
    // cells, but onAppear/onDisappear is what tells this specific card
    // instance to start/stop its own player rather than every card in the
    // grid starting one the moment the view model's `items` array loads).
    private var previewEligible: Bool {
        item.isVideo && item.locked != true && (settings?.autoplayPreviews ?? false) && item.url != nil
    }

    // "Muted previews" governs autoplay itself, not just the audio track --
    // mirrors media.jsx's `autoPlay={mutedPreview}` exactly: with sound-on
    // previews requested, this falls back to the static thumbnail (tap
    // through to MediaDetailView for real, controllable playback) rather
    // than autoplaying WITH sound in a scrolling feed, which every mobile
    // browser blocks outright and would be startling even where allowed.
    private var previewMuted: Bool { settings?.mutedPreviews ?? true }
    // tabIsActive: a background tab's cards never get onDisappear, so
    // without it their previews would keep playing out of sight.
    private var shouldShowLivePreview: Bool { previewEligible && previewMuted && isOnScreen && tabIsActive }

    private var previewURL: URL? {
        guard let urlString = item.url, var components = URLComponents(string: urlString) else { return nil }
        var queryItems = (components.queryItems ?? []).filter { $0.name != "quality" }
        queryItems.append(URLQueryItem(name: "quality", value: "low"))
        components.queryItems = queryItems
        return components.url
    }

    // "card_info_display" -- mirrors web's four gallery-info-* CSS modes
    // (see CardInfoDisplay's doc comment). Below/minimal render as normal
    // flow content under the thumbnail; overlay renders inside the
    // thumbnail's own bounds with a scrim; hidden renders neither.
    // Nocturne defaults to overlay (title over a scrim) when the viewer
    // hasn't chosen -- the staggered grid reads as a wall of images, and
    // a caption row under every tile breaks that up.
    private var infoDisplay: CardInfoDisplay { CardInfoDisplay(settings?.cardInfoDisplay ?? CardInfoDisplay.overlay.rawValue) }
    private var borderStyle: MediaBorderStyle { MediaBorderStyle(settings?.mediaBorderStyle) }
    private var cornerRadius: CGFloat {
        switch borderStyle {
        case .soft, .crisp: return 6
        default: return Nyx.Radius.card - 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(aspectRatio ?? Appearance.cardAspectRatio(settings?.cardAspectRatio), contentMode: .fit)
                .overlay(thumbnail)
                .overlay { if shouldShowLivePreview, let player = previewController.player {
                    GridPreviewVideoView(player: player)
                        .modifier(VideoPreviewBlur(active: settings?.blurVideoPreviews ?? false))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } }
                .overlay(alignment: .bottom) { if infoDisplay == .overlay { scrim } }
                .overlay(alignment: .bottom) { if infoDisplay == .overlay { footer(overlayStyle: true) } }
                .overlay(alignment: .topTrailing) { kindBadge }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .modifier(MediaBorderModifier(style: borderStyle, cornerRadius: cornerRadius))
                // Shadow cast by a plain rounded rectangle behind the card,
                // not by the whole composited card: a shadow on the card
                // itself made Core Animation re-render the card offscreen
                // on every scroll frame to find its outline.
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
                )

            if infoDisplay == .below || infoDisplay == .minimal {
                footer(overlayStyle: false)
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear {
            isOnScreen = false
            previewController.stop()
        }
        // `.task(id:)` cancels its previous Task the moment the id
        // changes (or the view disappears) -- exactly the debounce this
        // needs: fast-scrolling past a card flips shouldShowLivePreview
        // true-then-false before the sleep ever finishes, so the
        // cancellation check below stops it from ever starting a real
        // AVPlayer for a card the viewer never actually stopped on.
        .task(id: shouldShowLivePreview) {
            guard shouldShowLivePreview, let url = previewURL else {
                previewController.stop()
                return
            }
            // 150ms, not the original 350 -- long enough to skip a card
            // that flashes past mid-fling, but 350 turned out to routinely
            // be longer than a card stays continuously on screen during a
            // normal scroll flick, so previews rarely got the chance to
            // start at all (reported as "scrolling through Discover, only
            // gifs are actually playing" -- GIFs need no such gate).
            // Tightened on both platforms together.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            previewController.start(url: url, muted: previewMuted)
        }
    }

    // A dark gradient anchored to the bottom edge so the title/stat footer
    // stays legible over busy thumbnails without a solid overlay flattening
    // the whole card. Overlay mode only.
    private var scrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.7), .black.opacity(0)],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: 64)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func footer(overlayStyle: Bool) -> some View {
        if infoDisplay != .hidden {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(item.title?.nilIfEmpty ?? "Untitled")
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.bold)
                    .lineLimit(1)
                // "minimal" drops the stat, same as web's
                // .gallery-info-minimal .media-copy p { display: none }.
                if infoDisplay != .minimal {
                    Spacer(minLength: 4)
                    if let likeCount = item.likeCount, likeCount > 0 {
                        Label("\(likeCount)", systemImage: "heart.fill")
                            .labelStyle(.compactStat)
                    }
                }
            }
            .font(.caption2)
            // Color.primary (not the bare .primary HierarchicalShapeStyle
            // shorthand) so both ternary branches are the same concrete
            // Color type -- foregroundStyle's generic parameter needs one
            // single type, and mixing Color with HierarchicalShapeStyle
            // across a ternary's branches wouldn't type-check.
            .foregroundStyle(overlayStyle ? Color.white.opacity(0.9) : Color.primary)
            .padding(.horizontal, overlayStyle ? 10 : 4)
            .padding(.bottom, overlayStyle ? 9 : 0)
        }
    }

    @ViewBuilder
    private var kindBadge: some View {
        if item.locked == true {
            badgeIcon("lock.fill")
        } else if item.isVideo {
            badgeIcon("play.fill")
        }
    }

    private func badgeIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .bold))
            .frame(width: 24, height: 24)
            // Solid tint, not a material: a live blur per video card was
            // re-sampled on every scroll frame (same fix as the website's
            // glass pass).
            .background(Color.black.opacity(0.5), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .foregroundStyle(.white)
            .padding(8)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.locked == true {
            LinearGradient(colors: [Nyx.glow, Nyx.glowAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: "eye.slash.fill").foregroundStyle(.white.opacity(0.8)))
        } else if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            CachedAsyncImage(url: url, diagnostics: ImageLoadDiagnosticsContext(mediaId: item.id, mediaKind: item.mediaKind ?? "", context: "feed-card")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(Nyx.glow.opacity(0.35)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Rectangle().fill(Nyx.glow.opacity(0.25))
                }
            }
        } else {
            Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}

/// Mirrors web's four `gallery-border-*` treatments (see MediaBorderStyle's
/// doc comment): glow/neon add an accent-tinted shadow, neon additionally
/// draws a visible accent-colored stroke. none/soft/crisp differ only by
/// the corner radius MediaCard already applies before this modifier runs.
private struct MediaBorderModifier: ViewModifier {
    let style: MediaBorderStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .none, .soft:
            content
        case .crisp:
            content.overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
        case .glow:
            content.shadow(color: Color.accentColor.opacity(0.35), radius: 8)
        case .neon:
            content
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                )
                .shadow(color: Color.accentColor.opacity(0.45), radius: 12)
        }
    }
}

/// Mirrors web's `.blurred-video-thumb` CSS class (`filter: blur(3px)
/// saturate(0.86) brightness(0.84); transform: scale(1.035)`) -- the slight
/// scale-up hides the blur radius's edge falloff at the card's clipped
/// corners, same reason the web version scales too. SwiftUI's `.brightness`
/// is additive, not the multiplicative darkening CSS's brightness(0.84)
/// does, so -0.16 is a visual approximation, not a pixel-identical match.
private struct VideoPreviewBlur: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .blur(radius: 3)
                .saturation(0.86)
                .brightness(-0.16)
                .scaleEffect(1.035)
        } else {
            content
        }
    }
}

private struct CompactStatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactStatLabelStyle {
    static var compactStat: CompactStatLabelStyle { CompactStatLabelStyle() }
}
