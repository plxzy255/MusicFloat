import Foundation
import OSLog

/// Pulls millisecond-accurate timed lyrics from the Apple Music web API.
///
/// Uses the same endpoints the web player at `music.apple.com` does:
/// `amp-api.music.apple.com/v1/catalog/{sf}/songs/{id}` with the user's own
/// `media-user-token` cookie + a developer JWT scraped from the web player.
/// Returns TTML carrying both line- and syllable-level timing.
@MainActor
final class AppleMusicWebLyricsProvider {
    private let session: URLSession
    private let bootstrap: AppleMusicTokenBootstrap
    private var cachedStorefront: String?
    private var cachedLanguage: String?
    private var storefrontFetchedAt: Date = .distantPast

    init(
        session: URLSession = .shared,
        bootstrap: AppleMusicTokenBootstrap = .shared
    ) {
        self.session = session
        self.bootstrap = bootstrap
    }

    /// Returns a TTML-parsed document, `nil` if no lyrics are available for
    /// this track on this account, or throws on network / auth failures so
    /// the caller can decide whether to fall back.
    func lyrics(for track: NowPlayingTrack) async throws -> LyricsDocument? {
        guard let mediaUserToken = MediaUserTokenStore.read(),
              !mediaUserToken.isEmpty else {
            return nil
        }
        let devToken = try await bootstrap.token()

        // Resolve storefront (once per ~24h is fine — only changes on
        // account-region change).
        let (storefront, language) = try await ensureStorefront(
            developerToken: devToken,
            mediaUserToken: mediaUserToken
        )

        guard let identity = await AppleMusicCatalogResolver.resolve(
            track: track,
            developerToken: devToken,
            mediaUserToken: mediaUserToken,
            cachedStorefront: storefront,
            session: session
        ) else {
            AppTelemetry.performance.info("AM web: could not resolve catalog ID for track")
            return nil
        }

        do {
            return try await fetchLyrics(
                identity: identity,
                language: language,
                developerToken: devToken,
                mediaUserToken: mediaUserToken
            )
        } catch let error as APIError where error == .unauthorized {
            // Try once more with a freshly minted token in case the cached
            // one rotated mid-session.
            AppTelemetry.performance.info("AM web: 401, refreshing developer token")
            let fresh = try await bootstrap.token(forceRefresh: true)
            return try await fetchLyrics(
                identity: identity,
                language: language,
                developerToken: fresh,
                mediaUserToken: mediaUserToken
            )
        }
    }

    // MARK: - Storefront

    private struct StorefrontResponse: Decodable {
        struct Datum: Decodable {
            let id: String
            let attributes: Attributes?
        }
        struct Attributes: Decodable {
            let defaultLanguageTag: String?
        }
        let data: [Datum]
    }

    private func ensureStorefront(
        developerToken: String,
        mediaUserToken: String
    ) async throws -> (storefront: String, language: String) {
        if let storefront = cachedStorefront,
           let language = cachedLanguage,
           Date().timeIntervalSince(storefrontFetchedAt) < 86_400 {
            return (storefront, language)
        }
        var req = URLRequest(url: URL(string: "https://amp-api.music.apple.com/v1/me/storefront")!)
        req.timeoutInterval = 5
        applyAuthHeaders(to: &req, developerToken: developerToken, mediaUserToken: mediaUserToken)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        let decoded = try JSONDecoder().decode(StorefrontResponse.self, from: data)
        guard let first = decoded.data.first else { throw APIError.emptyResponse }
        let language = first.attributes?.defaultLanguageTag ?? "en-US"
        cachedStorefront = first.id
        cachedLanguage = language
        storefrontFetchedAt = Date()
        AppTelemetry.performance.info("AM web: storefront=\(first.id, privacy: .public) lang=\(language, privacy: .public)")
        return (first.id, language)
    }

    // MARK: - Lyrics

    private struct SongResponse: Decodable {
        struct Datum: Decodable {
            let relationships: Relationships?
        }
        struct Relationships: Decodable {
            let lyrics: LyricsRel?
            let syllableLyrics: LyricsRel?
            enum CodingKeys: String, CodingKey {
                case lyrics
                case syllableLyrics = "syllable-lyrics"
            }
        }
        struct LyricsRel: Decodable {
            let data: [LyricsDatum]
        }
        struct LyricsDatum: Decodable {
            let attributes: LyricsAttrs?
        }
        struct LyricsAttrs: Decodable {
            let ttml: String?
        }
        let data: [Datum]
    }

    private func fetchLyrics(
        identity: AppleMusicCatalogResolver.Identity,
        language: String,
        developerToken: String,
        mediaUserToken: String
    ) async throws -> LyricsDocument? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(identity.storefront)/songs/\(identity.songID)")!
        components.queryItems = [
            URLQueryItem(name: "include[songs]", value: "albums,lyrics,syllable-lyrics"),
            URLQueryItem(name: "l", value: language)
        ]
        guard let url = components.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        applyAuthHeaders(to: &req, developerToken: developerToken, mediaUserToken: mediaUserToken)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        let decoded = try JSONDecoder().decode(SongResponse.self, from: data)
        // Prefer syllable lyrics — they're a superset of plain timed lyrics
        // and carry the word-level timing for future per-syllable rendering.
        let ttml = decoded.data.first?.relationships?.syllableLyrics?.data.first?.attributes?.ttml
            ?? decoded.data.first?.relationships?.lyrics?.data.first?.attributes?.ttml
        guard let ttml, !ttml.isEmpty else {
            AppTelemetry.performance.info("AM web: catalog row has no lyrics ttml")
            return nil
        }
        return TTMLParser.parse(ttml: ttml)
    }

    // MARK: - Helpers

    private func applyAuthHeaders(
        to req: inout URLRequest,
        developerToken: String,
        mediaUserToken: String
    ) {
        req.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        req.setValue(mediaUserToken, forHTTPHeaderField: "media-user-token")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    enum APIError: Error, Equatable {
        case transport
        case unauthorized
        case badStatus(Int)
        case emptyResponse
    }
}
