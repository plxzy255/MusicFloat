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
enum LRCLIBLyricsProvider {
    private static let requestTimeout: TimeInterval = 8
    private static let durationMatchWindow: Double = 8

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
        session: URLSession = .shared
    ) async throws -> LyricsDocument? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        if let exact = try await fetchExact(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            session: session
        ) {
            return exact
        }

        return try await search(
            title: title,
            artist: artist,
            duration: duration,
            session: session
        )
    }

    // MARK: - Exact

    private static func fetchExact(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let doc = LyricsParser.parse(
            synced: decoded.syncedLyrics,
            plain: decoded.plainLyrics,
            source: .lrclib
        )
        return doc
    }

    // MARK: - Search

    private static func search(
        title: String,
        artist: String,
        duration: TimeInterval,
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let items = try JSONDecoder().decode([SearchItem].self, from: data)
        guard let best = pickBest(from: items, queryDuration: duration) else {
            return nil
        }
        return LyricsParser.parse(
            synced: best.syncedLyrics,
            plain: best.plainLyrics,
            source: .lrclib
        )
    }

    /// Prefer items that have synced lyrics and a close duration match.
    private static func pickBest(from items: [SearchItem], queryDuration: Double) -> SearchItem? {
        let viable = items.filter { item in
            let hasSynced = (item.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let hasPlain = (item.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            return hasSynced || hasPlain
        }
        guard !viable.isEmpty else { return nil }

        func score(_ item: SearchItem) -> Double {
            var s = 0.0
            if item.syncedLyrics?.isEmpty == false { s += 1.0 }
            if queryDuration > 0, let d = item.duration, d > 0 {
                let delta = abs(d - queryDuration)
                s += max(0, 1.0 - min(delta, durationMatchWindow) / durationMatchWindow)
            }
            return s
        }

        return viable.max { score($0) < score($1) }
    }
}
