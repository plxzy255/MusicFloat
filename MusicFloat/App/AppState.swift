import Foundation
import OSLog
import Observation

enum OverlayWidthPreset: String, CaseIterable, Identifiable, Sendable {
    case compact
    case medium
    case wide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact:
            "Compact"
        case .medium:
            "Medium"
        case .wide:
            "Wide"
        }
    }

    var width: Double {
        switch self {
        case .compact:
            420
        case .medium:
            520
        case .wide:
            620
        }
    }
}

enum OverlayContentState: Equatable, Sendable {
    case loading
    case ready
    case unavailable
    case failed(String)

    var displayName: String {
        switch self {
        case .loading:
            "Loading"
        case .ready:
            "Ready"
        case .unavailable:
            "Unavailable"
        case .failed:
            "Error"
        }
    }
}

struct LyricsOverlaySnapshot: Equatable, Sendable {
    let contentState: OverlayContentState
    let statusText: String
    let trackText: String
    let lyricText: String
    let activeLine: LyricLine?
    let effectiveLyricTime: TimeInterval
    let translationText: String?
    let attributionText: String
    let widthPreset: OverlayWidthPreset
}

struct LyricsOverlaySnapshotBuilder: Sendable {
    private let syncEngine = LyricsSyncEngine()

    static func activeSyllableIndex(in line: LyricLine, at effectiveLyricTime: TimeInterval) -> Int? {
        guard !line.syllables.isEmpty else {
            return nil
        }

        if let activeIndex = line.syllables.firstIndex(where: { syllable in
            syllable.startTime <= effectiveLyricTime && effectiveLyricTime < syllable.endTime
        }) {
            return activeIndex
        }

        return line.syllables.lastIndex { syllable in
            syllable.startTime <= effectiveLyricTime
        }
    }

    func makeSnapshot(
        contentState: OverlayContentState,
        playerState: PlayerState,
        lyricsDocument: LyricsDocument,
        translation: LyricTranslation,
        showsTranslation: Bool,
        widthPreset: OverlayWidthPreset,
        lyricOffsetSeconds: Double = 0
    ) -> LyricsOverlaySnapshot {
        let trackText = playerState.track?.displayTitle ?? "Waiting for playback"

        switch contentState {
        case .loading:
            return LyricsOverlaySnapshot(
                contentState: contentState,
                statusText: "Preparing lyrics",
                trackText: trackText,
                lyricText: "Listening for a mock playback snapshot...",
                activeLine: nil,
                effectiveLyricTime: playerState.elapsedTime + lyricOffsetSeconds + lyricsDocument.offsetCorrection,
                translationText: nil,
                attributionText: "Mock pipeline",
                widthPreset: widthPreset
            )
        case .unavailable:
            return LyricsOverlaySnapshot(
                contentState: contentState,
                statusText: playerState.statusLine,
                trackText: trackText,
                lyricText: "Lyrics unavailable for this track",
                activeLine: nil,
                effectiveLyricTime: playerState.elapsedTime + lyricOffsetSeconds + lyricsDocument.offsetCorrection,
                translationText: showsTranslation ? "Translation will wait for lyrics" : nil,
                attributionText: "No provider result",
                widthPreset: widthPreset
            )
        case .failed(let message):
            return LyricsOverlaySnapshot(
                contentState: contentState,
                statusText: "Provider error",
                trackText: trackText,
                lyricText: message,
                activeLine: nil,
                effectiveLyricTime: playerState.elapsedTime + lyricOffsetSeconds + lyricsDocument.offsetCorrection,
                translationText: nil,
                attributionText: "Mock failure state",
                widthPreset: widthPreset
            )
        case .ready:
            let effectiveLyricTime = playerState.elapsedTime + lyricOffsetSeconds + lyricsDocument.offsetCorrection
            let activeLine = syncEngine.activeLine(
                in: lyricsDocument,
                at: playerState.elapsedTime + lyricOffsetSeconds
            )
            let lyricText = activeLine?.text ?? "Lyrics unavailable"
            let translationText = activeLine.flatMap { line in
                showsTranslation ? translation.text(for: line) : nil
            }

            return LyricsOverlaySnapshot(
                contentState: contentState,
                statusText: playerState.statusLine,
                trackText: trackText,
                lyricText: lyricText,
                activeLine: activeLine,
                effectiveLyricTime: effectiveLyricTime,
                translationText: translationText,
                attributionText: Self.attributionText(
                    lyricsDocument: lyricsDocument,
                    translation: translation,
                    showsTranslation: showsTranslation
                ),
                widthPreset: widthPreset
            )
        }
    }

    private static func attributionText(
        lyricsDocument: LyricsDocument,
        translation: LyricTranslation,
        showsTranslation: Bool
    ) -> String {
        let sourceLanguageIdentifier = translation.sourceLanguageIdentifier
            ?? lyricsDocument.sourceLanguageIdentifier
        guard let sourceLanguageIdentifier else {
            return lyricsDocument.attribution
        }

        let sourceName = localizedLanguageName(for: sourceLanguageIdentifier)
        guard showsTranslation,
              !sameLanguageFamily(sourceLanguageIdentifier, translation.targetLanguageIdentifier) else {
            return "\(lyricsDocument.attribution) - \(sourceName)"
        }

        let targetName = localizedLanguageName(for: translation.targetLanguageIdentifier)
        return "\(lyricsDocument.attribution) - \(sourceName) to \(targetName)"
    }

    private static func sameLanguageFamily(_ lhs: String, _ rhs: String) -> Bool {
        let lhsLanguage = Locale.Language(identifier: lhs)
        let rhsLanguage = Locale.Language(identifier: rhs)
        if lhsLanguage.minimalIdentifier == rhsLanguage.minimalIdentifier {
            return true
        }
        guard let lhsCode = lhsLanguage.languageCode?.identifier,
              let rhsCode = rhsLanguage.languageCode?.identifier else {
            return false
        }
        return lhsCode == rhsCode
    }

    private static func localizedLanguageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

@MainActor
@Observable
final class AppState {
    var isOverlayVisible = false
    var isMockPreviewRunning = false
    var isLiveModeRunning = false
    var providerRuntimeState: ProviderRuntimeState = .idle
    var translationRuntimeState: TranslationRuntimeState = .idle
    var overlayContentState: OverlayContentState = .ready
    var playerState: PlayerState
    var lyricsDocument: LyricsDocument
    var translation: LyricTranslation
    var runtimeFeatureFlags = RuntimeFeatureFlags.architectureDefault
    var showsTranslation: Bool
    var preferredTranslationLanguageIdentifier: String
    var overlayWidthPreset: OverlayWidthPreset
    var reduceHiddenMemoryUsage: Bool
    /// Global default offset used when the current track has no remembered
    /// per-track offset. Positive values advance lyrics; negative delay them.
    var lyricOffsetSeconds: Double
    /// Remembered offsets per `NowPlayingTrack.id`. Persisted so once a track
    /// is tuned, the offset is automatic on next play.
    private(set) var perTrackOffsets: [String: Double]
    /// High-frequency elapsed-time updates from the playback tick. Kept
    /// separate from `playerState` so the menu (which observes only stable
    /// fields like track/status) doesn't get re-rendered on every tick —
    /// macOS MenuBarExtra(.menu) re-renders interrupt mouse tracking.
    private(set) var liveElapsedTime: TimeInterval = 0
    private(set) var liveElapsedUpdatedAt: Date = .distantPast

    private let snapshotBuilder = LyricsOverlaySnapshotBuilder()
    private let userDefaults: UserDefaults
    private static let perTrackOffsetsKey = "perTrackLyricOffsets"
    private static let preferredTranslationLanguageIdentifierKey = "preferredTranslationLanguageIdentifier"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        playerState = MockMusicAppBridge.previewState
        lyricsDocument = MockLyricsProvider.previewDocument

        let languageIdentifier = Self.validStoredLanguageIdentifier(
            userDefaults.string(forKey: Self.preferredTranslationLanguageIdentifierKey)
        ) ?? Self.systemLanguageIdentifier
        preferredTranslationLanguageIdentifier = languageIdentifier
        userDefaults.set(languageIdentifier, forKey: Self.preferredTranslationLanguageIdentifierKey)
        translation = MockTranslationProvider.previewTranslation(targetLanguageIdentifier: languageIdentifier)
        showsTranslation = userDefaults.object(forKey: "showTranslation") as? Bool ?? true
        overlayWidthPreset = OverlayWidthPreset(
            rawValue: userDefaults.string(forKey: "overlayWidthPreset") ?? OverlayWidthPreset.medium.rawValue
        ) ?? .medium
        reduceHiddenMemoryUsage = userDefaults.object(forKey: "reduceHiddenMemoryUsage") as? Bool ?? true
        lyricOffsetSeconds = userDefaults.object(forKey: "lyricOffsetSeconds") as? Double ?? 0
        perTrackOffsets = (userDefaults.dictionary(forKey: Self.perTrackOffsetsKey) as? [String: Double]) ?? [:]
        liveElapsedTime = playerState.elapsedTime
        liveElapsedUpdatedAt = playerState.updatedAt
    }

    /// Effective offset used for sync — per-track if known, otherwise the
    /// global default. Computed, not stored, so it tracks player state.
    var effectiveLyricOffsetSeconds: Double {
        if let trackID = playerState.track?.id, let perTrack = perTrackOffsets[trackID] {
            return perTrack
        }
        return lyricOffsetSeconds
    }

    /// Effective elapsed time used by lyric sync paths. During live or mock
    /// preview the playback tick updates this without invalidating broader
    /// menu state; otherwise the stable player snapshot is authoritative.
    var effectiveElapsedTime: TimeInterval {
        if isLiveModeRunning || isMockPreviewRunning {
            return liveElapsedTime
        }
        return playerState.elapsedTime
    }

    /// Where the current effective offset comes from. Used by the menu so
    /// the user knows whether their nudge will affect just this track or
    /// the global default.
    enum LyricOffsetScope: Equatable {
        case perTrack(trackID: String)
        case global
    }

    var lyricOffsetScope: LyricOffsetScope {
        if let trackID = playerState.track?.id, perTrackOffsets[trackID] != nil {
            return .perTrack(trackID: trackID)
        }
        return .global
    }

    var overlaySnapshot: LyricsOverlaySnapshot {
        // Build an effective PlayerState that substitutes the high-frequency
        // tick value in for elapsedTime, so the overlay reflects smooth
        // playback while menu-observed fields stay stable.
        let effectiveState = PlayerState(
            playbackStatus: playerState.playbackStatus,
            track: playerState.track,
            elapsedTime: effectiveElapsedTime,
            updatedAt: liveElapsedUpdatedAt
        )
        return snapshotBuilder.makeSnapshot(
            contentState: overlayContentState,
            playerState: effectiveState,
            lyricsDocument: lyricsDocument,
            translation: translation,
            showsTranslation: showsTranslation,
            widthPreset: overlayWidthPreset,
            lyricOffsetSeconds: effectiveLyricOffsetSeconds
        )
    }

    var preferredTranslationLanguageName: String {
        Self.localizedLanguageName(for: preferredTranslationLanguageIdentifier)
    }

    var lyricsSourceLanguageName: String {
        guard let sourceLanguageIdentifier = lyricsDocument.sourceLanguageIdentifier else {
            return "Unknown"
        }
        return Self.localizedLanguageName(for: sourceLanguageIdentifier)
    }

    var pendingTranslationDownload: (source: String, target: String)? {
        translationRuntimeState.downloadLanguages
    }

    // MARK: - Lyric offset

    /// Nudges the effective offset. If a track is playing, the nudge is
    /// stored against that track; otherwise it modifies the global default.
    func nudgeLyricOffset(by delta: Double) {
        let rounded = { (v: Double) in ((v * 100).rounded() / 100) }
        if let trackID = playerState.track?.id {
            let base = perTrackOffsets[trackID] ?? lyricOffsetSeconds
            let next = rounded(base + delta)
            perTrackOffsets[trackID] = next
            userDefaults.set(perTrackOffsets, forKey: Self.perTrackOffsetsKey)
            AppTelemetry.settings.info("Per-track lyric offset for track set to \(next)")
        } else {
            lyricOffsetSeconds = rounded(lyricOffsetSeconds + delta)
            userDefaults.set(lyricOffsetSeconds, forKey: "lyricOffsetSeconds")
            AppTelemetry.settings.info("Global lyric offset nudged to \(self.lyricOffsetSeconds)")
        }
    }

    /// Clears the per-track offset for the current track (falls back to
    /// global) if one exists; otherwise resets the global default to 0.
    func resetLyricOffset() {
        if let trackID = playerState.track?.id, perTrackOffsets[trackID] != nil {
            perTrackOffsets.removeValue(forKey: trackID)
            userDefaults.set(perTrackOffsets, forKey: Self.perTrackOffsetsKey)
            AppTelemetry.settings.info("Per-track lyric offset cleared")
        } else {
            lyricOffsetSeconds = 0
            userDefaults.set(0, forKey: "lyricOffsetSeconds")
            AppTelemetry.settings.info("Global lyric offset reset")
        }
    }

    /// Wipes every remembered per-track offset. Global stays.
    func clearAllPerTrackOffsets() {
        perTrackOffsets.removeAll()
        userDefaults.set(perTrackOffsets, forKey: Self.perTrackOffsetsKey)
        AppTelemetry.settings.info("All per-track lyric offsets cleared")
    }

    func applyPreferences(
        showsTranslation: Bool,
        preferredTranslationLanguageIdentifier: String,
        overlayWidthPreset: OverlayWidthPreset,
        reduceHiddenMemoryUsage: Bool
    ) -> Bool {
        let normalizedLanguageIdentifier = Self.validStoredLanguageIdentifier(preferredTranslationLanguageIdentifier)
            ?? Self.systemLanguageIdentifier
        let translationPreferenceChanged = self.showsTranslation != showsTranslation
            || self.preferredTranslationLanguageIdentifier != normalizedLanguageIdentifier
        self.showsTranslation = showsTranslation
        self.preferredTranslationLanguageIdentifier = normalizedLanguageIdentifier
        self.overlayWidthPreset = overlayWidthPreset
        self.reduceHiddenMemoryUsage = reduceHiddenMemoryUsage
        userDefaults.set(normalizedLanguageIdentifier, forKey: Self.preferredTranslationLanguageIdentifierKey)
        if translationPreferenceChanged {
            clearTranslation()
            setTranslationRuntimeState(showsTranslation ? .idle : .unavailable(reason: "Translation hidden"))
        }

        AppTelemetry.settings.info(
            "Preferences applied translation=\(showsTranslation) language=\(normalizedLanguageIdentifier, privacy: .public) width=\(overlayWidthPreset.rawValue, privacy: .public) reduceHiddenMemory=\(reduceHiddenMemoryUsage)"
        )
        return translationPreferenceChanged
    }

    func updatePlayerState(_ playerState: PlayerState) {
        self.playerState = playerState
        // Seed the live tick fields from the authoritative state so
        // the overlay's elapsed reflects it immediately.
        liveElapsedTime = playerState.elapsedTime
        liveElapsedUpdatedAt = playerState.updatedAt
    }

    /// High-frequency update — does NOT touch `playerState`, so menu/Settings
    /// observers don't re-evaluate. Called from the playback tick.
    func updateLiveElapsedTime(_ value: TimeInterval) {
        liveElapsedTime = value
        liveElapsedUpdatedAt = Date()
    }

    func setProviderRuntimeState(_ state: ProviderRuntimeState) {
        providerRuntimeState = state
        AppTelemetry.performance.info("Provider runtime state set to \(state.displayName, privacy: .public)")
    }

    func applyLyricsDocument(_ document: LyricsDocument) {
        lyricsDocument = document
        let syllableCount = document.lines.reduce(0) { total, line in
            total + line.syllables.count
        }
        AppTelemetry.performance.info(
            "Lyrics document applied source=\(document.source.rawValue, privacy: .public) timed=\(document.isTimed) line_count=\(document.lines.count) syllable_count=\(syllableCount)"
        )
    }

    func applyTranslation(_ translation: LyricTranslation) {
        self.translation = translation
    }

    func clearTranslation() {
        translation = LyricTranslation(
            targetLanguageIdentifier: preferredTranslationLanguageIdentifier,
            sourceLanguageIdentifier: lyricsDocument.sourceLanguageIdentifier,
            lines: []
        )
    }

    func setTranslationRuntimeState(_ state: TranslationRuntimeState) {
        translationRuntimeState = state
        AppTelemetry.performance.info("Translation runtime state set to \(state.displayName, privacy: .public)")
    }

    func applyProviderReady() {
        providerRuntimeState = .ready
        overlayContentState = .ready
        AppTelemetry.performance.info("Provider pipeline ready")
    }

    func applyProviderUnavailable() {
        providerRuntimeState = .unavailable
        overlayContentState = .unavailable
        AppTelemetry.performance.info("Provider pipeline unavailable")
    }

    func applyProviderFailure(_ message: String) {
        providerRuntimeState = .failed(message)
        overlayContentState = .failed(message)
        AppTelemetry.performance.info("Provider pipeline failed")
    }

    func setMockPreviewRunning(_ isRunning: Bool) {
        isMockPreviewRunning = isRunning
    }

    func setLiveModeRunning(_ isRunning: Bool) {
        isLiveModeRunning = isRunning
    }

    func resetMockPlayback() {
        updatePlayerState(MockMusicAppBridge.previewState)
        overlayContentState = .ready
        AppTelemetry.performance.info("Mock playback snapshot reset")
    }

    func setOverlayContentState(_ state: OverlayContentState) {
        overlayContentState = state
        AppTelemetry.performance.info("Mock overlay state set to \(state.displayName, privacy: .public)")
    }

    static var systemLanguageIdentifier: String {
        let preferred = Locale.preferredLanguages.first
        return LyricsDocument.normalizedLanguageIdentifier(preferred)
            ?? Locale.current.language.minimalIdentifier
    }

    static func validStoredLanguageIdentifier(_ rawValue: String?) -> String? {
        guard let normalized = LyricsDocument.normalizedLanguageIdentifier(rawValue) else {
            return nil
        }
        let firstComponent = normalized.split(separator: "-").first.map(String.init) ?? normalized
        guard (2...3).contains(firstComponent.count),
              firstComponent.allSatisfy({ $0.isLetter }) else {
            return nil
        }
        return normalized
    }

    static func localizedLanguageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
