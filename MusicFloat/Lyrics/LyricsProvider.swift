import Foundation
import OSLog

enum LyricsProviderResult: Equatable, Sendable {
    case available(LyricsDocument)
    case unavailable
    case failed(String)
}

@MainActor
protocol LyricsProvider {
    var displayName: String { get }

    func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult
}

struct MockLyricsProvider: LyricsProvider {
    let displayName = "Mock lyrics provider"

    func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
        .available(Self.previewDocument)
    }

    static let previewDocument = LyricsDocument(
        source: .mock,
        lines: [
            LyricLine(id: 0, text: "The app wakes quiet in the menu bar", startTime: 0),
            LyricLine(id: 1, text: "A floating line waits for the song", startTime: 18),
            LyricLine(id: 2, text: "Translation follows, soft and native", startTime: 42),
            LyricLine(id: 3, text: "Every future hook stays behind a bridge", startTime: 78)
        ],
        isTimed: true
    )
}

/// Real public lyrics provider.
///
/// Priority: AppleScript library → Apple Music web API (if configured) →
/// LRCLIB → AX panel. The Apple Music web path requires a one-time
/// `media-user-token` paste in Settings; when not configured we skip it.
/// The LRCLIB → AX fallback can be disabled via the
/// `lrclibFallbackEnabled` toggle so the user can pin the experience to
/// "Apple data only".
@MainActor
final class PublicLyricsProvider: LyricsProvider {
    let displayName = "Public lyrics provider"

    private var memoryCache: [String: LyricsDocument] = [:]
    private let maxCacheEntries = 64
    private var cacheOrder: [String] = []
    private let appleMusicWeb = AppleMusicWebLyricsProvider()

    /// When false, only AppleScript library + Apple Music web API are
    /// consulted. UserDefaults-backed so the setting persists.
    var lrclibFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: "lrclibFallbackEnabled") as? Bool ?? true
    }

    func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
        if track.providerName.lowercased().contains("mock") {
            return .unavailable
        }
        if let cached = memoryCache[track.id] {
            return .available(cached)
        }

        // 1) AppleScript library lyrics. These are canonical for local/
        // library tracks and always plain text. `fetchCurrentTrackLyrics`
        // will also fall back to an AX panel scrape internally when
        // AppleScript has nothing — for catalog tracks that's _always_ the
        // case, so we'd short-circuit every catalog-track lookup before the
        // web API ever runs. Filter strictly to canonical `.musicApp`
        // results; AX is reconsidered at the end of the pipeline.
        let appleScriptDoc = MusicAppLyricsProvider.fetchCurrentTrackLyrics()
        if let doc = appleScriptDoc, doc.source == .musicApp {
            if shouldCache(document: doc) {
                store(doc, for: track.id)
            }
            AppTelemetry.performance.info("Lyrics hit \(doc.source.rawValue, privacy: .public) timed=\(doc.isTimed) lines=\(doc.lines.count)")
            return .available(doc)
        }
        if MusicAppLyricsProvider.requiresAccessibilityPermission {
            return .failed("Allow MusicFloat in Privacy & Security > Accessibility to use Music lyrics.")
        }

        // 2) Apple Music web API — millisecond-accurate TTML straight from
        // Apple. Only runs when the user has pasted their media-user-token
        // in Settings.
        if MediaUserTokenStore.isConfigured {
            do {
                if let doc = try await appleMusicWeb.lyrics(for: track) {
                    store(doc, for: track.id)
                    AppTelemetry.performance.info("Lyrics hit appleMusicWeb timed=\(doc.isTimed) lines=\(doc.lines.count)")
                    return .available(doc)
                }
                AppTelemetry.performance.info("AM web returned no lyrics")
            } catch is CancellationError {
                return .unavailable
            } catch {
                AppTelemetry.performance.error("AM web error: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Fallback gate — when disabled we stop here and surface "no lyrics"
        // so the user sees the authoritative Apple result instead of a
        // potentially mismatched LRCLIB upload.
        guard lrclibFallbackEnabled else {
            return .unavailable
        }

        // 3) LRCLIB — prefer synced lyrics over the AX single-line scrape so
        // we can show a full timed document. Calibration against the Music UI
        // happens later in the refresh tick.
        do {
            if let doc = try await LRCLIBLyricsProvider.fetch(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration
            ) {
                if doc.isTimed {
                    store(doc, for: track.id)
                    AppTelemetry.performance.info("Lyrics hit lrclib timed=true lines=\(doc.lines.count)")
                    return .available(doc)
                }
                // Untimed LRCLIB — keep as fallback, but try AX first so we
                // at least get the live highlighted line if the panel is open.
                if let axDoc = MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineDocument() {
                    AppTelemetry.performance.info("Lyrics hit musicAppUI (LRCLIB plain ignored) lines=\(axDoc.lines.count)")
                    return .available(axDoc)
                }
                AppTelemetry.performance.info("Lyrics hit lrclib timed=false lines=\(doc.lines.count)")
                store(doc, for: track.id)
                return .available(doc)
            }
        } catch is CancellationError {
            return .unavailable
        } catch {
            AppTelemetry.performance.error("LRCLIB error: \(error.localizedDescription, privacy: .public)")
        }

        // 4) AX panel — final catalog fallback when LRCLIB has nothing.
        if let axDoc = MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineDocument() {
            AppTelemetry.performance.info("Lyrics hit \(axDoc.source.rawValue, privacy: .public) timed=\(axDoc.isTimed) lines=\(axDoc.lines.count)")
            return .available(axDoc)
        }
        if MusicAppLyricsProvider.shouldRetryVisibleLyrics {
            for _ in 1...6 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else {
                    return .unavailable
                }
                if let doc = MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineDocument() {
                    AppTelemetry.performance.info("Lyrics hit \(doc.source.rawValue, privacy: .public) timed=\(doc.isTimed) lines=\(doc.lines.count)")
                    return .available(doc)
                }
            }
            AppTelemetry.performance.info("Music.app UI lyrics still loading; no LRCLIB match")
        }

        return .unavailable
    }

    private func store(_ document: LyricsDocument, for key: String) {
        if memoryCache[key] == nil {
            cacheOrder.append(key)
        }
        memoryCache[key] = document
        if cacheOrder.count > maxCacheEntries {
            let evict = cacheOrder.removeFirst()
            memoryCache.removeValue(forKey: evict)
        }
    }

    private func shouldCache(document: LyricsDocument) -> Bool {
        !(document.source == .musicAppUI && !document.isTimed && document.lines.count == 1)
    }
}

struct ExperimentalLyricsProviderPlaceholder: LyricsProvider {
    let displayName = "Experimental lyrics provider placeholder"

    func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
        .unavailable
    }
}

struct DisabledLyricsProvider: LyricsProvider {
    let displayName = "Disabled lyrics provider"

    func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
        .unavailable
    }
}
