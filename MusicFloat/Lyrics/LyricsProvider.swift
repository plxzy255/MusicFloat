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

    struct Dependencies {
        var fetchAppleScriptLyrics: @MainActor () async -> LyricsDocument?
        var requiresAccessibilityPermission: @MainActor () -> Bool
        var hasAccessibilityPermission: @MainActor () -> Bool
        var shouldRetryVisibleLyrics: @MainActor () -> Bool
        var isMediaUserTokenConfigured: @MainActor () -> Bool
        var fetchAppleMusicWebLyrics: @MainActor (NowPlayingTrack, String) async throws -> LyricsDocument?
        var isLRCLIBFallbackEnabled: @MainActor () -> Bool
        var fetchLRCLIBLyrics: @MainActor (NowPlayingTrack, String) async throws -> LyricsDocument?
        var fetchAXLyrics: @MainActor () -> LyricsDocument?
        var sleep: @MainActor (UInt64) async throws -> Void
        var now: @MainActor () -> Date

        static func live(appleMusicWeb: AppleMusicWebLyricsProvider) -> Self {
            Self(
                fetchAppleScriptLyrics: {
                    await MusicAppLyricsProvider.fetchCurrentTrackLyrics()
                },
                requiresAccessibilityPermission: {
                    MusicAppLyricsProvider.requiresAccessibilityPermission
                },
                hasAccessibilityPermission: {
                    MusicAppLyricsProvider.hasAccessibilityPermission
                },
                shouldRetryVisibleLyrics: {
                    MusicAppLyricsProvider.shouldRetryVisibleLyrics
                },
                isMediaUserTokenConfigured: {
                    MediaUserTokenStore.isConfigured
                },
                fetchAppleMusicWebLyrics: { track, lookupID in
                    try await appleMusicWeb.lyrics(for: track, lookupID: lookupID)
                },
                isLRCLIBFallbackEnabled: {
                    UserDefaults.standard.object(forKey: "lrclibFallbackEnabled") as? Bool ?? true
                },
                fetchLRCLIBLyrics: { track, lookupID in
                    try await LRCLIBLyricsProvider.fetch(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        duration: track.duration,
                        lookupID: lookupID
                    )
                },
                fetchAXLyrics: {
                    MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineDocument()
                },
                sleep: { nanoseconds in
                    try await Task.sleep(nanoseconds: nanoseconds)
                },
                now: {
                    Date()
                }
            )
        }
    }

    private enum CacheEntry {
        case document(LyricsDocument, expiresAt: Date)
        case unavailable(expiresAt: Date)
    }

    private enum CachePolicy {
        case documentIfCacheable
        case unavailable
        case none
    }

    private struct LookupOutcome {
        let result: LyricsProviderResult
        let cachePolicy: CachePolicy

        static func available(_ document: LyricsDocument) -> Self {
            Self(result: .available(document), cachePolicy: .documentIfCacheable)
        }

        static func unavailable(cachePolicy: CachePolicy = .none) -> Self {
            Self(result: .unavailable, cachePolicy: cachePolicy)
        }

        static func failed(_ message: String) -> Self {
            Self(result: .failed(message), cachePolicy: .none)
        }
    }

    private var memoryCache: [String: CacheEntry] = [:]
    private struct InFlightLookup {
        let lookupID: String
        let task: Task<LookupOutcome, Never>
    }

    private var inFlightTasks: [String: InFlightLookup] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 64
    private static let documentCacheTTL: TimeInterval = 6 * 60 * 60
    private static let unavailableCacheTTL: TimeInterval = 10 * 60
    private let appleMusicWeb = AppleMusicWebLyricsProvider()
    private let dependencies: Dependencies

    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? Dependencies.live(appleMusicWeb: appleMusicWeb)
    }

    /// When false, only AppleScript library + Apple Music web API are
    /// consulted. UserDefaults-backed so the setting persists.
    var lrclibFallbackEnabled: Bool {
        dependencies.isLRCLIBFallbackEnabled()
    }

    func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
        await AppTelemetry.measure("PublicLyricsProvider.lyrics") {
            await lyricsImpl(for: track)
        }
    }

    private func lyricsImpl(for track: NowPlayingTrack) async -> LyricsProviderResult {
        if track.providerName.lowercased().contains("mock") {
            return .unavailable
        }
        if let cached = cachedResult(for: track.id, now: dependencies.now()) {
            return cached
        }
        if let inFlight = inFlightTasks[track.id] {
            AppTelemetry.performance.info(
                "Lyrics lookup joined in-flight task lookup=\(inFlight.lookupID, privacy: .public)"
            )
            let outcome = await inFlight.task.value
            if !Task.isCancelled {
                cache(outcome, for: track.id, now: dependencies.now())
            }
            return outcome.result
        }

        let lookupID = Self.makeLookupID()
        let task = Task { @MainActor [self, track, lookupID] in
            await fetchLyricsUncached(for: track, lookupID: lookupID)
        }
        inFlightTasks[track.id] = InFlightLookup(lookupID: lookupID, task: task)
        let outcome = await task.value
        inFlightTasks.removeValue(forKey: track.id)
        if !Task.isCancelled {
            cache(outcome, for: track.id, now: dependencies.now())
        }
        return outcome.result
    }

    private func fetchLyricsUncached(for track: NowPlayingTrack, lookupID: String) async -> LookupOutcome {
        AppTelemetry.performance.info(
            "Lyrics lookup started lookup=\(lookupID, privacy: .public)"
        )
        // 1) AppleScript library lyrics. These are canonical for local/library
        // tracks and always plain text. Keep this lookup library-only; the AX
        // panel scrape is intentionally the final fallback because traversing
        // Music.app's accessibility tree can briefly stall the UI.
        var sawTransientProviderFailure = false
        var completedAXFallback = false
        let appleScriptStartedAt = Date()
        let appleScriptDoc = await dependencies.fetchAppleScriptLyrics()
        AppTelemetry.performance.notice(
            "Lyrics stage AppleScript finished lookup=\(lookupID, privacy: .public) elapsed=\(Date().timeIntervalSince(appleScriptStartedAt), privacy: .public)"
        )
        if let doc = appleScriptDoc, doc.source == .musicApp {
            AppTelemetry.performance.info("Lyrics hit lookup=\(lookupID, privacy: .public) source=\(doc.source.rawValue, privacy: .public) timed=\(doc.isTimed) lines=\(doc.lines.count)")
            return .available(doc)
        }
        let axPermissionWasNeeded = dependencies.requiresAccessibilityPermission()
        let webConfigured = dependencies.isMediaUserTokenConfigured()

        // 2) Apple Music web API — millisecond-accurate TTML straight from
        // Apple. Only runs when the user has pasted their media-user-token
        // in Settings.
        if webConfigured {
            do {
                let webStartedAt = Date()
                if let doc = try await dependencies.fetchAppleMusicWebLyrics(track, lookupID) {
                    AppTelemetry.performance.notice(
                        "Lyrics stage AppleMusicWeb finished lookup=\(lookupID, privacy: .public) elapsed=\(Date().timeIntervalSince(webStartedAt), privacy: .public) result=hit"
                    )
                    AppTelemetry.performance.info("Lyrics hit lookup=\(lookupID, privacy: .public) source=appleMusicWeb timed=\(doc.isTimed) lines=\(doc.lines.count)")
                    return .available(doc)
                }
                AppTelemetry.performance.notice(
                    "Lyrics stage AppleMusicWeb finished lookup=\(lookupID, privacy: .public) elapsed=\(Date().timeIntervalSince(webStartedAt), privacy: .public) result=miss"
                )
                AppTelemetry.performance.info("AM web returned no lyrics lookup=\(lookupID, privacy: .public)")
            } catch is CancellationError {
                return .unavailable()
            } catch {
                sawTransientProviderFailure = true
                AppTelemetry.performance.error("AM web error lookup=\(lookupID, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
            }
        }

        // Fallback gate — when disabled we stop here and surface "no lyrics"
        // so the user sees the authoritative Apple result instead of a
        // potentially mismatched LRCLIB upload.
        guard lrclibFallbackEnabled else {
            return .unavailable()
        }

        // 3) LRCLIB — prefer synced lyrics over the AX single-line scrape so
        // we can show a full timed document. Calibration against the Music UI
        // happens later in the refresh tick.
        do {
            let lrclibStartedAt = Date()
            if let doc = try await dependencies.fetchLRCLIBLyrics(track, lookupID) {
                AppTelemetry.performance.notice(
                    "Lyrics stage LRCLIB finished lookup=\(lookupID, privacy: .public) elapsed=\(Date().timeIntervalSince(lrclibStartedAt), privacy: .public) result=hit"
                )
                if doc.isTimed {
                    AppTelemetry.performance.info("Lyrics hit lookup=\(lookupID, privacy: .public) source=lrclib timed=true lines=\(doc.lines.count)")
                    return .available(doc)
                }
                // Untimed LRCLIB — keep as fallback, but try AX first so we
                // at least get the live highlighted line if the panel is open.
                if dependencies.hasAccessibilityPermission(),
                   let axDoc = dependencies.fetchAXLyrics() {
                    AppTelemetry.performance.info("Lyrics hit lookup=\(lookupID, privacy: .public) source=musicAppUI reason=lrclib_plain_ignored lines=\(axDoc.lines.count)")
                    return .available(axDoc)
                }
                AppTelemetry.performance.info("Lyrics hit lookup=\(lookupID, privacy: .public) source=lrclib timed=false lines=\(doc.lines.count)")
                return .available(doc)
            }
            AppTelemetry.performance.notice(
                "Lyrics stage LRCLIB finished lookup=\(lookupID, privacy: .public) elapsed=\(Date().timeIntervalSince(lrclibStartedAt), privacy: .public) result=miss"
            )
        } catch is CancellationError {
            return .unavailable()
        } catch {
            sawTransientProviderFailure = true
            AppTelemetry.performance.error("LRCLIB error lookup=\(lookupID, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
        }

        // 4) AX panel — final catalog fallback when LRCLIB has nothing.
        if dependencies.hasAccessibilityPermission() {
            completedAXFallback = true
            if let axDoc = dependencies.fetchAXLyrics() {
                AppTelemetry.performance.info("Lyrics hit lookup=\(lookupID, privacy: .public) source=\(axDoc.source.rawValue, privacy: .public) timed=\(axDoc.isTimed) lines=\(axDoc.lines.count)")
                return .available(axDoc)
            }
            if dependencies.shouldRetryVisibleLyrics() {
                for _ in 1...6 {
                    try? await dependencies.sleep(500_000_000)
                    guard !Task.isCancelled else {
                        return .unavailable()
                    }
                    if let doc = dependencies.fetchAXLyrics() {
                        AppTelemetry.performance.info("Lyrics hit lookup=\(lookupID, privacy: .public) source=\(doc.source.rawValue, privacy: .public) timed=\(doc.isTimed) lines=\(doc.lines.count)")
                        return .available(doc)
                    }
                }
                AppTelemetry.performance.info("Music.app UI lyrics still loading lookup=\(lookupID, privacy: .public) reason=no_lrclib_match")
            }
        } else if axPermissionWasNeeded || appleScriptDoc?.source == .musicAppUI {
            return .failed(Self.accessibilityPermissionMessage)
        }

        let canNegativeCacheMiss = webConfigured && completedAXFallback && !sawTransientProviderFailure
        return .unavailable(cachePolicy: canNegativeCacheMiss ? .unavailable : .none)
    }

    private static let accessibilityPermissionMessage =
        "Allow MusicFloat in Privacy & Security > Accessibility to use Music lyrics."

    private static func makeLookupID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private func cachedResult(for key: String, now: Date) -> LyricsProviderResult? {
        guard let entry = memoryCache[key] else {
            return nil
        }
        switch entry {
        case let .document(document, expiresAt):
            guard expiresAt > now else {
                removeCachedEntry(for: key)
                return nil
            }
            return .available(document)
        case let .unavailable(expiresAt):
            guard expiresAt > now else {
                removeCachedEntry(for: key)
                return nil
            }
            return .unavailable
        }
    }

    private func cache(_ outcome: LookupOutcome, for key: String, now: Date) {
        switch (outcome.result, outcome.cachePolicy) {
        case let (.available(document), .documentIfCacheable) where shouldCache(document: document):
            store(.document(document, expiresAt: now.addingTimeInterval(Self.documentCacheTTL)), for: key)
        case (.unavailable, .unavailable):
            store(.unavailable(expiresAt: now.addingTimeInterval(Self.unavailableCacheTTL)), for: key)
        case (.available, _), (.unavailable, _), (.failed, _):
            break
        }
    }

    private func store(_ entry: CacheEntry, for key: String) {
        if memoryCache[key] == nil {
            cacheOrder.append(key)
        }
        memoryCache[key] = entry
        if cacheOrder.count > maxCacheEntries {
            let evict = cacheOrder.removeFirst()
            memoryCache.removeValue(forKey: evict)
        }
    }

    private func removeCachedEntry(for key: String) {
        memoryCache.removeValue(forKey: key)
        cacheOrder.removeAll { $0 == key }
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
