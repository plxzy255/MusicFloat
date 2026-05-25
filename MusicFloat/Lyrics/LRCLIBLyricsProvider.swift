import Foundation
import OSLog

/// Thin client for https://lrclib.net.
///
/// Tries `/api/get` (exact match on artist+title+album+duration) first; if that
/// 404s, falls back to `/api/search`. Returns the best `LyricsDocument` it can
/// find, or `nil` if there is no usable result.
///
/// Kept intentionally simpler than PlayStatus's version: no parallel artist
/// candidate expansion, no scoring tuning. We can add that complexity back if
/// real-world matching starts missing.
nonisolated enum LRCLIBLyricsProvider {
    private static let requestTimeout: TimeInterval = 4
    private static let durationMatchWindow: Double = 6

    struct Response: Decodable, Sendable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    struct SearchItem: Decodable, Sendable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    /// Returns a document or nil. `nil` means "no match"; throws are reserved
    /// for network/parsing failures so callers can distinguish.
    static func fetch(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        lookupID: String? = nil,
        session: URLSession = .shared
    ) async throws -> LyricsDocument? {
        let effectiveLookupID = lookupID ?? Self.makeLookupID()
        return try await AppTelemetry.measure("LRCLIBLyricsProvider.fetch") {
            try await fetchImpl(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                lookupID: effectiveLookupID,
                session: session
            )
        }
    }

    private static func fetchImpl(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        lookupID: String,
        session: URLSession
    ) async throws -> LyricsDocument? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        if let exact = try await fetchExact(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lookupID: lookupID,
            session: session
        ) {
            return exact
        }

        return try await search(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lookupID: lookupID,
            session: session
        )
    }

    // MARK: - Exact

    private static func fetchExact(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        lookupID: String,
        session: URLSession
    ) async throws -> LyricsDocument? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("MusicFloat/0.1 (+https://github.com)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppTelemetry.performance.error(
                "LRCLIB request failed endpoint=exact lookup=\(lookupID, privacy: .public) reason=\(Self.safeNetworkReason(error), privacy: .public)"
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try await decode(Response.self, from: data)
        let doc = await parseLyrics(
            synced: decoded.syncedLyrics,
            plain: decoded.plainLyrics,
            source: .lrclib
        )
        if doc != nil {
            AppTelemetry.performance.info(
                "LRCLIB exact match lookup=\(lookupID, privacy: .public) result=hit duration=\(duration, privacy: .public)"
            )
        }
        return doc
    }

    // MARK: - Search

    private static func search(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        lookupID: String,
        session: URLSession
    ) async throws -> LyricsDocument? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("MusicFloat/0.1 (+https://github.com)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppTelemetry.performance.error(
                "LRCLIB request failed endpoint=search lookup=\(lookupID, privacy: .public) reason=\(Self.safeNetworkReason(error), privacy: .public)"
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let items = try await decode([SearchItem].self, from: data)
        guard let best = pickBest(
            from: items,
            queryTitle: title,
            queryArtist: artist,
            queryAlbum: album,
            queryDuration: duration
        ) else {
            return nil
        }
        AppTelemetry.performance.info(
            "LRCLIB search fallback chose lookup=\(lookupID, privacy: .public) hasSynced=\((best.syncedLyrics?.isEmpty == false), privacy: .public) duration=\(best.duration ?? 0, privacy: .public) queryDuration=\(duration, privacy: .public) candidates=\(items.count, privacy: .public)"
        )
        return await parseLyrics(
            synced: best.syncedLyrics,
            plain: best.plainLyrics,
            source: .lrclib
        )
    }

    /// Prefer items that have synced lyrics, close metadata, and a close
    /// duration. Reject weak timed matches rather than showing synced lyrics
    /// that look authoritative but drift badly.
    private static func pickBest(
        from items: [SearchItem],
        queryTitle: String,
        queryArtist: String,
        queryAlbum: String,
        queryDuration: Double
    ) -> SearchItem? {
        let normalizedTitle = normalizedSearchText(queryTitle)
        let normalizedArtist = normalizedSearchText(queryArtist)
        let normalizedAlbum = normalizedSearchText(queryAlbum)

        let viable = items.filter { item in
            let hasSynced = (item.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let hasPlain = (item.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            guard hasSynced || hasPlain else { return false }
            guard titleScore(item.trackName, query: normalizedTitle) >= 0.75 else { return false }
            guard artistScore(item.artistName, query: normalizedArtist) >= 0.5 else { return false }
            if hasSynced, queryDuration > 0, let d = item.duration, d > 0 {
                return abs(d - queryDuration) <= durationMatchWindow
            }
            return true
        }
        guard !viable.isEmpty else { return nil }

        func score(_ item: SearchItem) -> Double {
            var s = 0.0
            if item.syncedLyrics?.isEmpty == false { s += 4.0 }
            s += titleScore(item.trackName, query: normalizedTitle) * 3.0
            s += artistScore(item.artistName, query: normalizedArtist) * 2.0
            s += albumScore(item.albumName, query: normalizedAlbum)
            if queryDuration > 0, let d = item.duration, d > 0 {
                let delta = abs(d - queryDuration)
                s += max(0, 2.0 - min(delta, durationMatchWindow) / durationMatchWindow * 2.0)
            }
            return s
        }

        return viable.max { score($0) < score($1) }
    }

    private static func normalizedSearchText(_ value: String?) -> String {
        guard let value else { return "" }
        let withoutParentheticals = value.replacing(
            /\s*[\(\[].*?[\)\]]\s*/,
            with: " "
        )
        let folded = withoutParentheticals
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func titleScore(_ candidate: String?, query: String) -> Double {
        let candidate = normalizedSearchText(candidate)
        guard !candidate.isEmpty, !query.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.contains(query) || query.contains(candidate) { return 0.85 }
        return tokenOverlap(candidate, query)
    }

    private static func artistScore(_ candidate: String?, query: String) -> Double {
        let candidate = normalizedSearchText(candidate)
        guard !candidate.isEmpty, !query.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.contains(query) || query.contains(candidate) { return 0.75 }
        return tokenOverlap(candidate, query)
    }

    private static func albumScore(_ candidate: String?, query: String) -> Double {
        guard !query.isEmpty else { return 0 }
        let candidate = normalizedSearchText(candidate)
        guard !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.contains(query) || query.contains(candidate) { return 0.75 }
        return tokenOverlap(candidate, query) * 0.75
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.split(separator: " "))
        let right = Set(rhs.split(separator: " "))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        return Double(shared) / Double(max(left.count, right.count))
    }

    private static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(type, from: data)
        }.value
    }

    private static func parseLyrics(
        synced: String?,
        plain: String?,
        source: LyricsSource
    ) async -> LyricsDocument? {
        await Task.detached(priority: .userInitiated) {
            LyricsParser.parse(synced: synced, plain: plain, source: source)
        }.value
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

    private static func makeLookupID() -> String {
        String(UUID().uuidString.prefix(8))
    }
}
