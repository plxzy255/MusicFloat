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
    private let developerToken: (Bool) async throws -> String
    private let mediaUserToken: () -> String?
    private let catalogIdentity: (
        NowPlayingTrack,
        String,
        String,
        String?,
        URLSession
    ) async -> AppleMusicCatalogResolver.Identity?
    private let dataForRequest: (URLRequest) async throws -> (Data, URLResponse)
    private let preferredLyricLanguage: () -> String?
    private var cachedStorefront: String?
    private var cachedLanguage: String?
    private var storefrontFetchedAt: Date = .distantPast

    init(
        session: URLSession = .shared,
        bootstrap: AppleMusicTokenBootstrap = .shared,
        developerToken: ((Bool) async throws -> String)? = nil,
        mediaUserToken: @escaping () -> String? = { MediaUserTokenStore.read() },
        catalogIdentity: (@MainActor (
            NowPlayingTrack,
            String,
            String,
            String?,
            URLSession
        ) async -> AppleMusicCatalogResolver.Identity?)? = nil,
        dataForRequest: (((URLRequest) async throws -> (Data, URLResponse)))? = nil,
        preferredLyricLanguage: @escaping () -> String? = {
            UserDefaults.standard.string(forKey: "preferredLyricLanguage")
        }
    ) {
        self.session = session
        self.developerToken = developerToken ?? { try await bootstrap.token(forceRefresh: $0) }
        self.mediaUserToken = mediaUserToken
        self.catalogIdentity = catalogIdentity ?? {
            await AppleMusicCatalogResolver.resolve(
                track: $0,
                developerToken: $1,
                mediaUserToken: $2,
                cachedStorefront: $3,
                session: $4
            )
        }
        self.dataForRequest = dataForRequest ?? { try await session.data(for: $0) }
        self.preferredLyricLanguage = preferredLyricLanguage
    }

    /// Returns a TTML-parsed document, `nil` if no lyrics are available for
    /// this track on this account, or throws on network / auth failures so
    /// the caller can decide whether to fall back.
    func lyrics(for track: NowPlayingTrack) async throws -> LyricsDocument? {
        try await AppTelemetry.measure("AppleMusicWebLyricsProvider.lyrics") {
            try await lyricsImpl(for: track)
        }
    }

    private func lyricsImpl(for track: NowPlayingTrack) async throws -> LyricsDocument? {
        guard let mediaUserToken = mediaUserToken(),
              !mediaUserToken.isEmpty else {
            return nil
        }
        let devToken = try await developerToken(false)

        // Resolve storefront (once per ~24h is fine — only changes on
        // account-region change).
        let (storefront, language) = try await ensureStorefront(
            developerToken: devToken,
            mediaUserToken: mediaUserToken
        )

        guard let identity = await catalogIdentity(track, devToken, mediaUserToken, storefront, session) else {
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
            let fresh = try await developerToken(true)
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

        let (data, response) = try await dataForRequest(req)
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
            let ttmlLocalizations: TTMLLocalizations?
        }
        let data: [Datum]
    }

    private struct SyllableLyricsResponse: Decodable {
        struct Datum: Decodable {
            let attributes: SongResponse.LyricsAttrs?
        }
        let data: [Datum]
    }

    struct TTMLVariant: Equatable {
        enum Source: String {
            case primary
            case localization
            case fallbackLyrics
        }

        let ttml: String
        let language: String?
        let source: Source
    }

    private enum TTMLLocalizations: Decodable {
        case values([LocalizedTTML])

        struct LocalizedTTML: Decodable {
            let language: String?
            let ttml: String

            private enum CodingKeys: String, CodingKey {
                case language
                case languageTag
                case locale
                case l
                case ttml
            }

            init(language: String?, ttml: String) {
                self.language = language
                self.ttml = ttml
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                ttml = try container.decode(String.self, forKey: .ttml)
                language = try container.decodeIfPresent(String.self, forKey: .language)
                    ?? container.decodeIfPresent(String.self, forKey: .languageTag)
                    ?? container.decodeIfPresent(String.self, forKey: .locale)
                    ?? container.decodeIfPresent(String.self, forKey: .l)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .values([LocalizedTTML(language: nil, ttml: value)])
                return
            }
            if let values = try? container.decode([LocalizedTTML].self) {
                self = .values(values)
                return
            }
            if let keyed = try? container.decode([String: String].self) {
                let sortedKeyed = keyed.sorted { lhs, rhs in
                    let lhsLanguage = normalizedLanguage(lhs.key) ?? lhs.key
                    let rhsLanguage = normalizedLanguage(rhs.key) ?? rhs.key
                    if lhsLanguage != rhsLanguage {
                        return lhsLanguage < rhsLanguage
                    }
                    return lhs.key < rhs.key
                }
                self = .values(sortedKeyed.map { LocalizedTTML(language: $0.key, ttml: $0.value) })
                return
            }
            self = .values([])
        }

        var variants: [TTMLVariant] {
            switch self {
            case .values(let values):
                values.map {
                    TTMLVariant(
                        ttml: $0.ttml,
                        language: normalizedLanguage($0.language) ?? TTMLParser.languageTag(in: $0.ttml),
                        source: .localization
                    )
                }
            }
        }
    }

    private func fetchLyrics(
        identity: AppleMusicCatalogResolver.Identity,
        language: String,
        developerToken: String,
        mediaUserToken: String
    ) async throws -> LyricsDocument? {
        try await AppTelemetry.measure("AppleMusicWebLyricsProvider.fetchLyrics") {
            try await fetchLyricsImpl(
                identity: identity,
                language: language,
                developerToken: developerToken,
                mediaUserToken: mediaUserToken
            )
        }
    }

    private func fetchLyricsImpl(
        identity: AppleMusicCatalogResolver.Identity,
        language: String,
        developerToken: String,
        mediaUserToken: String
    ) async throws -> LyricsDocument? {
        do {
            if let dedicated = try await fetchDedicatedSyllableLyrics(
                identity: identity,
                language: language,
                developerToken: developerToken,
                mediaUserToken: mediaUserToken
            ) {
                return dedicated
            }
            AppTelemetry.performance.info("AM web: dedicated syllable endpoint fallback reason=no_valid_ttml")
        } catch let error as APIError where error == .notFound {
            AppTelemetry.performance.info("AM web: dedicated syllable endpoint fallback reason=404")
        } catch is DecodingError {
            AppTelemetry.performance.info("AM web: dedicated syllable endpoint fallback reason=decode")
        }
        return try await fetchBroadLyrics(
            identity: identity,
            language: language,
            developerToken: developerToken,
            mediaUserToken: mediaUserToken
        )
    }

    private func fetchDedicatedSyllableLyrics(
        identity: AppleMusicCatalogResolver.Identity,
        language: String,
        developerToken: String,
        mediaUserToken: String
    ) async throws -> LyricsDocument? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(identity.storefront)/songs/\(identity.songID)/syllable-lyrics")!
        components.queryItems = [
            URLQueryItem(name: "l", value: language),
            URLQueryItem(name: "extend", value: "ttmlLocalizations")
        ]
        guard let url = components.url else { return nil }

        let decoded = try await fetchDecoded(SyllableLyricsResponse.self, url: url, developerToken: developerToken, mediaUserToken: mediaUserToken)
        let variants = variants(from: decoded.data.first?.attributes)
        AppTelemetry.performance.info("AM web: endpoint=syllable-lyrics localization_count=\(Self.localizationCount(in: variants))")
        return selectAndParse(variants: variants, storefrontLanguage: language, endpoint: "syllable-lyrics")
    }

    private func fetchBroadLyrics(
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

        let decoded: SongResponse
        do {
            decoded = try await fetchDecoded(SongResponse.self, url: url, developerToken: developerToken, mediaUserToken: mediaUserToken)
        } catch let error as APIError where error == .notFound {
            AppTelemetry.performance.info("AM web: songs-include fallback endpoint returned 404")
            return nil
        }
        // Prefer syllable lyrics — they're a superset of plain timed lyrics
        // and carry the word-level timing for future per-syllable rendering.
        var lyricVariants = variants(from: decoded.data.first?.relationships?.syllableLyrics?.data.first?.attributes)
        if lyricVariants.isEmpty,
           let attrs = decoded.data.first?.relationships?.lyrics?.data.first?.attributes {
            lyricVariants = variants(from: attrs, primarySource: TTMLVariant.Source.fallbackLyrics)
        }
        AppTelemetry.performance.info("AM web: endpoint=songs-include localization_count=\(Self.localizationCount(in: lyricVariants))")
        guard let document = selectAndParse(variants: lyricVariants, storefrontLanguage: language, endpoint: "songs-include") else {
            AppTelemetry.performance.info("AM web: catalog row has no lyrics ttml")
            return nil
        }
        return document
    }

    private func fetchDecoded<T: Decodable>(
        _ type: T.Type,
        url: URL,
        developerToken: String,
        mediaUserToken: String
    ) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        applyAuthHeaders(to: &req, developerToken: developerToken, mediaUserToken: mediaUserToken)

        let (data, response) = try await dataForRequest(req)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        if http.statusCode == 404 { throw APIError.notFound }
        guard (200...299).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        return try JSONDecoder().decode(type, from: data)
    }

    private func variants(
        from attributes: SongResponse.LyricsAttrs?,
        primarySource: TTMLVariant.Source = .primary
    ) -> [TTMLVariant] {
        var values: [TTMLVariant] = []
        if let ttml = attributes?.ttml, !ttml.isEmpty {
            values.append(TTMLVariant(
                ttml: ttml,
                language: TTMLParser.languageTag(in: ttml),
                source: primarySource
            ))
        }
        values.append(contentsOf: attributes?.ttmlLocalizations?.variants ?? [])
        return values
    }

    private func selectAndParse(
        variants: [TTMLVariant],
        storefrontLanguage: String,
        endpoint: String
    ) -> LyricsDocument? {
        let parseable = variants.compactMap { variant -> (TTMLVariant, LyricsDocument)? in
            guard !variant.ttml.isEmpty,
                  let document = TTMLParser.parse(ttml: variant.ttml) else {
                return nil
            }
            return (variant, document)
        }
        guard let selected = Self.selectBestTTML(
            from: parseable.map(\.0),
            preferredLyricLanguage: preferredLyricLanguage(),
            storefrontLanguage: storefrontLanguage
        ), let document = parseable.first(where: { $0.0 == selected })?.1 else {
            return nil
        }
        AppTelemetry.performance.info("AM web: selected endpoint=\(endpoint, privacy: .public) source=\(selected.source.rawValue, privacy: .public) language=\(selected.language ?? "unknown", privacy: .public)")
        return document
    }

    static func selectBestTTML(
        from variants: [TTMLVariant],
        preferredLyricLanguage: String?,
        storefrontLanguage: String
    ) -> TTMLVariant? {
        guard !variants.isEmpty else { return nil }
        if let original = variants.first(where: { $0.source == .primary && $0.language != nil }) {
            return original
        }
        if let preferred = firstMatch(in: variants, language: preferredLyricLanguage) {
            return preferred
        }
        if let storefront = firstMatch(in: variants, language: storefrontLanguage) {
            return storefront
        }
        return variants.first
    }

    private static func firstMatch(in variants: [TTMLVariant], language: String?) -> TTMLVariant? {
        guard let language = normalizedLanguage(language) else { return nil }
        return variants.first {
            guard let candidate = normalizedLanguage($0.language) else { return false }
            return candidate == language || candidate.split(separator: "-").first == language.split(separator: "-").first
        }
    }

    private static func localizationCount(in variants: [TTMLVariant]) -> Int {
        variants.filter { $0.source == .localization }.count
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.replacingOccurrences(of: "_", with: "-").lowercased()
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
        case notFound
        case badStatus(Int)
        case emptyResponse
    }
}
