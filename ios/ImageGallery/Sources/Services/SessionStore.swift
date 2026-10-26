import Combine
import Foundation

/// App-wide session state: current user + auth token lifecycle. Mirrors the
/// role `ctx.user`/`ctx.setSessionUser`/`ctx.logout` play in the web app's
/// `App.jsx`.
@MainActor
final class SessionStore: ObservableObject {
    @Published var currentUser: GalleryUser?
    @Published var isBootstrapping = true
    @Published var lastError: String?

    private let api = GalleryAPIClient.shared

    /// Runs once at launch: resolve the backend origin, and if a token is
    /// already in the Keychain from a previous session, validate it against
    /// `/api/me` before showing the signed-in shell.
    func bootstrap() async {
        // Launch used to wait for live-config.json (a GitHub Pages round
        // trip) before even starting /api/me. With an address already saved,
        // start right away; the refresh runs alongside, and a request that
        // fails because the address moved re-fetches it anyway
        // (GalleryAPIClient.sendWithRetry).
        if LiveConfigService.shared.hasKnownOrigin {
            Task { await LiveConfigService.shared.refresh() }
        } else {
            await LiveConfigService.shared.refresh()
        }
        if api.isAuthenticated {
            do {
                // Bounded, not a bare `try await api.me()` -- see Timeout.swift's
                // withTimeout doc comment: the shared URLSession's
                // waitsForConnectivity=true means a request made while the
                // network is genuinely unreachable at this instant otherwise
                // waits with no timeout ever firing, which previously meant
                // isBootstrapping could get stuck true forever (the reported
                // "sometimes stuck on an infinite loading screen"). A timeout
                // here is treated as "couldn't verify right now," not a
                // fatal auth failure -- see the catch below.
                currentUser = try await withTimeout(seconds: 12) { try await self.api.me() }
            } catch is TimedOutError {
                // Unlike a real 401/403, this isn't evidence the session is
                // actually invalid -- just that this attempt couldn't reach
                // the server in time, so (unlike the catch-all branch below)
                // the token is deliberately left in place rather than
                // cleared. currentUser is still nil here, though -- there's
                // no cached GalleryUser to restore, so RootView's `session.
                // currentUser != nil` check sends this to the login screen
                // for now, not a resumed session. That's a real UX
                // regression versus true offline resume, but it's a login
                // screen the person can act on (retry once connectivity is
                // back), not the unresponsive infinite spinner this
                // replaces -- and the very next successful bootstrap/
                // refreshCurrentUser() call, using the still-valid token,
                // puts them right back in without re-entering credentials.
                lastError = "Couldn't reach the server. Please try again."
            } catch {
                // Surface *why* — this is the only place a banned/suspended
                // account's session gets invalidated, and silently dropping
                // back to the login screen with no explanation would be
                // confusing (the backend's 403 detail already has the
                // human-readable ban reason/expiry).
                lastError = error.localizedDescription
                api.authToken = nil
                currentUser = nil
            }
        }
        isBootstrapping = false
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        let response = try await api.login(username: username, password: password)
        if let token = response.token {
            api.authToken = token
            currentUser = response.user
        }
        return response
    }

    func register(username: String, password: String, email: String?, displayName: String?) async throws -> AuthResponse {
        let response = try await api.register(username: username, password: password, email: email, displayName: displayName)
        if let token = response.token {
            api.authToken = token
            currentUser = response.user
        }
        return response
    }

    func completeTwoFactor(pendingToken: String, code: String) async throws {
        let response = try await api.verifyTwoFactor(pendingToken: pendingToken, code: code)
        if let token = response.token {
            api.authToken = token
            currentUser = response.user
        }
    }

    func logout() async {
        await api.logout()
        currentUser = nil
        BadgeService.setBadge(0)
    }

    /// Called when the app returns to the foreground — picks up account
    /// changes made elsewhere (web settings, or a ban/unban) while backgrounded.
    /// Unlike `bootstrap()`, a failure here doesn't force a logout on its own:
    /// a transient network hiccup shouldn't kick a signed-in user out, but a
    /// ban's 403 still needs to end the session and explain why.
    func refreshCurrentUser() async {
        guard api.isAuthenticated else { return }
        do {
            // Same waitsForConnectivity hang risk bootstrap() has (see
            // Timeout.swift) -- lower stakes here since nothing UI-blocking
            // awaits this call, but an unbounded task sitting around
            // per foreground event is still worth not leaving unbounded.
            currentUser = try await withTimeout(seconds: 12) { try await self.api.me() }
        } catch is TimedOutError {
            // Falls into the same "keep the existing session as-is" bucket
            // as the generic network-hiccup catch below.
        } catch let error as GalleryAPIError {
            if case .http(let status, let message) = error, status == 401 || status == 403 {
                lastError = message
                api.authToken = nil
                currentUser = nil
            }
        } catch {
            // Network/decoding hiccup — keep the existing session as-is.
        }
    }

    func setCurrentUser(_ user: GalleryUser) {
        currentUser = user
    }
}
