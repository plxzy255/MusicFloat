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
        URLSession,
        String
    ) async -> AppleMusicCatalogResolver.Resolution
    private let dataForRequest: (URLRequest) async throws -> (Data, URLResponse)
    private let preferredLyricLanguage: () -> String?
    private var cachedStorefront: String?
    private var cachedLanguage: String?
    private var storefrontFetchedAt: Date = .distantPast
    private var catalogMisses: [String: Date] = [:]
    private static let catalogMissTTL: TimeInterval = 10 * 60
    private static let maxCatalogMissEntries = 128

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
            URLSession,
            String
        ) async -> AppleMusicCatalogResolver.Resolution)? = nil,
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
                session: $4,
                lookupID: $5
            )
        }
        self.dataForRequest = dataForRequest ?? { try await session.data(for: $0) }
        self.preferredLyricLanguage = preferredLyricLanguage
    }

    /// Returns a TTML-parsed document, `nil` if no lyrics are available for
    /// this track on this account, or throws on network / auth / transient
    /// resolver failures so the caller can decide whether to fall back without
    /// poisoning a negative cache.
    func lyrics(for track: NowPlayingTrack, lookupID: String? = nil) async throws -> LyricsDocument? {
        let effectiveLookupID = lookupID ?? Self.makeLookupID()
        return try await AppTelemetry.measure("AppleMusicWebLyricsProvider.lyrics") {
            try await lyricsImpl(for: track, lookupID: effectiveLookupID)
        }
    }

    private func lyricsImpl(for track: NowPlayingTrack, lookupID: String) async throws -> LyricsDocument? {
        guard let mediaUserToken = mediaUserToken(),
              !mediaUserToken.isEmpty else {
            return nil
        }
        let devToken = try await developerToken(false)

        // Resolve storefront (once per ~24h is fine — only changes on
        // account-region change).
        let (storefront, storefrontLanguage) = try await ensureStorefront(
            developerToken: devToken,
            mediaUserToken: mediaUserToken
        )
        let requestLanguage = Self.normalizedLanguage(preferredLyricLanguage())

        let now = Date()
        if let missedAt = catalogMisses[track.id] {
            if now.timeIntervalSince(missedAt) < Self.catalogMissTTL {
                AppTelemetry.performance.info("AM web: catalog ID resolution skipped due to recent miss lookup=\(lookupID, privacy: .public)")
                return nil
            }
            catalogMisses.removeValue(forKey: track.id)
        }

        let identity: AppleMusicCatalogResolver.Identity
        switch await catalogIdentity(track, devToken, mediaUserToken, storefront, session, lookupID) {
        case .identity(let resolvedIdentity):
            identity = resolvedIdentity
        case .miss:
            storeCatalogMiss(for: track.id, now: now)
            AppTelemetry.performance.info("AM web: could not resolve catalog ID lookup=\(lookupID, privacy: .public)")
            return nil
        case .transientFailure:
            AppTelemetry.performance.info("AM web: catalog ID resolution failed transiently lookup=\(lookupID, privacy: .public)")
            throw APIError.transientCatalogResolution
        }
        catalogMisses.removeValue(forKey: track.id)

        do {
            return try await fetchLyrics(
                identity: identity,
                storefrontLanguage: storefrontLanguage,
                requestLanguage: requestLanguage,
                developerToken: devToken,
                mediaUserToken: mediaUserToken,
                lookupID: lookupID
            )
        } catch let error as APIError where error == .unauthorized {
            // Try once more with a freshly minted token in case the cached
            // one rotated mid-session.
            AppTelemetry.performance.info("AM web: 401, refreshing developer token lookup=\(lookupID, privacy: .public)")
            let fresh = try await developerToken(true)
            return try await fetchLyrics(
                identity: identity,
                storefrontLanguage: storefrontLanguage,
                requestLanguage: requestLanguage,
                developerToken: fresh,
                mediaUserToken: mediaUserToken,
                lookupID: lookupID
            )
        }
    }

    private func storeCatalogMiss(for trackID: String, now: Date) {
        catalogMisses[trackID] = now
        guard catalogMisses.count > Self.maxCatalogMissEntries else { return }
        let sortedKeys = catalogMisses.sorted { $0.value < $1.value }.map(\.key)
        for key in sortedKeys.prefix(catalogMisses.count - Self.maxCatalogMissEntries) {
            catalogMisses.removeValue(forKey: key)
        }
    }

    // MARK: - Storefront

    nonisolated private struct StorefrontResponse: Decodable, Sendable {
        struct Datum: Decodable, Sendable {
            let id: String
            let attributes: Attributes?
        }
        struct Attributes: Decodable, Sendable {
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

        let decoded = try await Self.decode(StorefrontResponse.self, from: data)
        guard let first = decoded.data.first else { throw APIError.emptyResponse }
        let language = first.attributes?.defaultLanguageTag ?? "en-US"
        cachedStorefront = first.id
        cachedLanguage = language
        storefrontFetchedAt = Date()
        AppTelemetry.performance.info("AM web: storefront=\(first.id, privacy: .public) lang=\(language, privacy: .public)")
        return (first.id, language)
    }

    // MARK: - Lyrics

    nonisolated private struct SongResponse: Decodable, Sendable {
        struct Datum: Decodable, Sendable {
            let relationships: Relationships?
        }
        struct Relationships: Decodable, Sendable {
            let lyrics: LyricsRel?
            let syllableLyrics: LyricsRel?
            enum CodingKeys: String, CodingKey {
                case lyrics
                case syllableLyrics = "syllable-lyrics"
            }
        }
        struct LyricsRel: Decodable, Sendable {
            let data: [LyricsDatum]
        }
        struct LyricsDatum: Decodable, Sendable {
            let attributes: LyricsAttrs?
        }
        struct LyricsAttrs: Decodable, Sendable {
            let ttml: String?
            let ttmlLocalizations: TTMLLocalizations?
        }
        let data: [Datum]
    }

    nonisolated private struct SyllableLyricsResponse: Decodable, Sendable {
        struct Datum: Decodable, Sendable {
            let attributes: SongResponse.LyricsAttrs?
        }
        let data: [Datum]
    }

    nonisolated struct TTMLVariant: Equatable, Sendable {
        enum Source: String, Sendable {
            case primary
            case localization
            case fallbackLyrics
        }

        let ttml: String
        let language: String?
        let source: Source
    }

    nonisolated private enum TTMLLocalizations: Decodable, Sendable {
        case values([LocalizedTTML])

        struct LocalizedTTML: Decodable, Sendable {
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
        storefrontLanguage: String,
        requestLanguage: String?,
        developerToken: String,
        mediaUserToken: String,
        lookupID: String
    ) async throws -> LyricsDocument? {
        try await AppTelemetry.measure("AppleMusicWebLyricsProvider.fetchLyrics") {
            try await fetchLyricsImpl(
                identity: identity,
                storefrontLanguage: storefrontLanguage,
                requestLanguage: requestLanguage,
                developerToken: developerToken,
                mediaUserToken: mediaUserToken,
                lookupID: lookupID
            )
        }
    }

    private func fetchLyricsImpl(
        identity: AppleMusicCatalogResolver.Identity,
        storefrontLanguage: String,
        requestLanguage: String?,
        developerToken: String,
        mediaUserToken: String,
        lookupID: String
    ) async throws -> LyricsDocument? {
        do {
            if let dedicated = try await fetchDedicatedSyllableLyrics(
                identity: identity,
                storefrontLanguage: storefrontLanguage,
                requestLanguage: requestLanguage,
                developerToken: developerToken,
                mediaUserToken: mediaUserToken,
                lookupID: lookupID
            ) {
                return dedicated
            }
            AppTelemetry.performance.info("AM web: dedicated syllable endpoint fallback lookup=\(lookupID, privacy: .public) reason=no_valid_ttml")
        } catch let error as APIError where error == .notFound {
            AppTelemetry.performance.info("AM web: dedicated syllable endpoint fallback lookup=\(lookupID, privacy: .public) reason=404")
        } catch is DecodingError {
            AppTelemetry.performance.info("AM web: dedicated syllable endpoint fallback lookup=\(lookupID, privacy: .public) reason=decode")
        }
        return try await fetchBroadLyrics(
            identity: identity,
            storefrontLanguage: storefrontLanguage,
            requestLanguage: requestLanguage,
            developerToken: developerToken,
            mediaUserToken: mediaUserToken,
            lookupID: lookupID
        )
    }

    private func fetchDedicatedSyllableLyrics(
        identity: AppleMusicCatalogResolver.Identity,
        storefrontLanguage: String,
        requestLanguage: String?,
        developerToken: String,
        mediaUserToken: String,
        lookupID: String
    ) async throws -> LyricsDocument? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(identity.storefront)/songs/\(identity.songID)/syllable-lyrics")!
        components.queryItems = [
            requestLanguage.map { URLQueryItem(name: "l", value: $0) },
            URLQueryItem(name: "extend", value: "ttmlLocalizations")
        ].compactMap { $0 }
        guard let url = components.url else { return nil }

        let decoded = try await fetchDecoded(SyllableLyricsResponse.self, url: url, developerToken: developerToken, mediaUserToken: mediaUserToken, lookupID: lookupID)
        let variants = variants(from: decoded.data.first?.attributes)
        AppTelemetry.performance.info("AM web: endpoint=syllable-lyrics lookup=\(lookupID, privacy: .public) localization_count=\(Self.localizationCount(in: variants))")
        return await selectAndParse(variants: variants, storefrontLanguage: storefrontLanguage, endpoint: "syllable-lyrics", lookupID: lookupID)
    }

    private func fetchBroadLyrics(
        identity: AppleMusicCatalogResolver.Identity,
        storefrontLanguage: String,
        requestLanguage: String?,
        developerToken: String,
        mediaUserToken: String,
        lookupID: String
    ) async throws -> LyricsDocument? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(identity.storefront)/songs/\(identity.songID)")!
        var queryItems = [
            URLQueryItem(name: "include[songs]", value: "albums,lyrics,syllable-lyrics")
        ]
        if let requestLanguage {
            queryItems.append(URLQueryItem(name: "l", value: requestLanguage))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        let decoded: SongResponse
        do {
            decoded = try await fetchDecoded(SongResponse.self, url: url, developerToken: developerToken, mediaUserToken: mediaUserToken, lookupID: lookupID)
        } catch let error as APIError where error == .notFound {
            AppTelemetry.performance.info("AM web: songs-include fallback endpoint returned 404 lookup=\(lookupID, privacy: .public)")
            return nil
        }
        // Prefer syllable lyrics — they're a superset of plain timed lyrics
        // and carry the word-level timing used by the overlay progress mask.
        var lyricVariants = variants(from: decoded.data.first?.relationships?.syllableLyrics?.data.first?.attributes)
        if lyricVariants.isEmpty,
           let attrs = decoded.data.first?.relationships?.lyrics?.data.first?.attributes {
            lyricVariants = variants(from: attrs, primarySource: TTMLVariant.Source.fallbackLyrics)
        }
        AppTelemetry.performance.info("AM web: endpoint=songs-include lookup=\(lookupID, privacy: .public) localization_count=\(Self.localizationCount(in: lyricVariants))")
        guard let document = await selectAndParse(variants: lyricVariants, storefrontLanguage: storefrontLanguage, endpoint: "songs-include", lookupID: lookupID) else {
            AppTelemetry.performance.info("AM web: catalog row has no lyrics ttml lookup=\(lookupID, privacy: .public)")
            return nil
        }
        return document
    }

    private func fetchDecoded<T: Decodable & Sendable>(
        _ type: T.Type,
        url: URL,
        developerToken: String,
        mediaUserToken: String,
        lookupID: String
    ) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        applyAuthHeaders(to: &req, developerToken: developerToken, mediaUserToken: mediaUserToken)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await dataForRequest(req)
        } catch {
            AppTelemetry.performance.error(
                "AM web request failed endpoint=\(Self.endpointFamily(for: url), privacy: .public) lookup=\(lookupID, privacy: .public) reason=\(Self.safeNetworkReason(error), privacy: .public)"
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        if http.statusCode == 404 { throw APIError.notFound }
        guard (200...299).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        return try await Self.decode(type, from: data)
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
        endpoint: String,
        lookupID: String
    ) async -> LyricsDocument? {
        let preferredLanguage = preferredLyricLanguage()
        let parseable = await Self.parseTTMLVariants(variants)
        guard let selected = Self.selectBestParsedTTML(
            from: parseable,
            preferredLyricLanguage: preferredLanguage,
            storefrontLanguage: storefrontLanguage
        ) else {
            return nil
        }
        AppTelemetry.performance.info(
            "AM web: selected endpoint=\(endpoint, privacy: .public) lookup=\(lookupID, privacy: .public) source=\(selected.variant.source.rawValue, privacy: .public) language=\(selected.variant.language ?? "unknown", privacy: .public) syllable_count=\(Self.syllableCount(in: selected.document), privacy: .public)"
        )
        return selected.document
    }

    private static func makeLookupID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    static func selectBestParsedTTML(
        from candidates: [(variant: TTMLVariant, document: LyricsDocument)],
        preferredLyricLanguage: String?,
        storefrontLanguage: String
    ) -> (variant: TTMLVariant, document: LyricsDocument)? {
        guard !candidates.isEmpty else { return nil }

        let syllableTimed = candidates.filter { syllableCount(in: $0.document) > 0 }
        if !syllableTimed.isEmpty,
           let selected = selectBestTTML(
               from: syllableTimed.map { $0.variant },
               preferredLyricLanguage: preferredLyricLanguage,
               storefrontLanguage: storefrontLanguage
           ),
           let match = syllableTimed.first(where: { $0.variant == selected }) {
            return match
        }

        guard let selected = selectBestTTML(
            from: candidates.map { $0.variant },
            preferredLyricLanguage: preferredLyricLanguage,
            storefrontLanguage: storefrontLanguage
        ) else {
            return nil
        }
        return candidates.first { $0.variant == selected }
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

    private static func syllableCount(in document: LyricsDocument) -> Int {
        document.lines.reduce(0) { $0 + $1.syllables.count }
    }

    nonisolated private static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(type, from: data)
        }.value
    }

    nonisolated private static func parseTTMLVariants(
        _ variants: [TTMLVariant]
    ) async -> [(variant: TTMLVariant, document: LyricsDocument)] {
        await Task.detached(priority: .userInitiated) {
            variants.compactMap { variant -> (variant: TTMLVariant, document: LyricsDocument)? in
                guard !variant.ttml.isEmpty,
                      let document = TTMLParser.parse(ttml: variant.ttml) else {
                    return nil
                }
                return (variant, document)
            }
        }.value
    }

    private static func endpointFamily(for url: URL) -> String {
        let path = url.path
        if path.contains("/syllable-lyrics") {
            return "syllable-lyrics"
        }
        if path.contains("/songs/") {
            return "songs"
        }
        if path.contains("/me/storefront") {
            return "storefront"
        }
        return "unknown"
    }

    private static func safeNetworkReason(_ error: any Error) -> String {
        guard let urlError = error as? URLError else {
            return "transport"
        }
        switch urlError.code {
        case .timedOut:
            return "timedOut"
        case .cancelled:
            return "cancelled"
        case .notConnectedToInternet:
            return "offline"
        default:
            return "urlError-\(urlError.code.rawValue)"
        }
    }

    nonisolated private static func normalizedLanguage(_ language: String?) -> String? {
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
        case transientCatalogResolution
    }
}
