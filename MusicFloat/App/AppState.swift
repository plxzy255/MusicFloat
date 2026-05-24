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
    let translationText: String?
    let attributionText: String
    let widthPreset: OverlayWidthPreset
}

struct LyricsOverlaySnapshotBuilder: Sendable {
    private let syncEngine = LyricsSyncEngine()

    func makeSnapshot(
        contentState: OverlayContentState,
        playerState: PlayerState,
        lyricsDocument: LyricsDocument,
        translation: LyricTranslation,
        showsTranslation: Bool,
        widthPreset: OverlayWidthPreset
    ) -> LyricsOverlaySnapshot {
        let trackText = playerState.track?.displayTitle ?? "Waiting for playback"

        switch contentState {
        case .loading:
            return LyricsOverlaySnapshot(
                contentState: contentState,
                statusText: "Preparing lyrics",
                trackText: trackText,
                lyricText: "Listening for a mock playback snapshot...",
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
                translationText: nil,
                attributionText: "Mock failure state",
                widthPreset: widthPreset
            )
        case .ready:
            let activeLine = syncEngine.activeLine(in: lyricsDocument, at: playerState.elapsedTime)
            let lyricText = activeLine?.text ?? "Lyrics unavailable"
            let translationText = activeLine.flatMap { line in
                showsTranslation ? translation.text(for: line) : nil
            }

            return LyricsOverlaySnapshot(
                contentState: contentState,
                statusText: playerState.statusLine,
                trackText: trackText,
                lyricText: lyricText,
                translationText: translationText,
                attributionText: "\(lyricsDocument.attribution) - \(translation.targetLanguage)",
                widthPreset: widthPreset
            )
        }
    }
}

@MainActor
@Observable
final class AppState {
    var isOverlayVisible = false
    var isMockPreviewRunning = false
    var isLiveModeRunning = false
    var providerRuntimeState: ProviderRuntimeState = .idle
    var overlayContentState: OverlayContentState = .ready
    var playerState: PlayerState
    var lyricsDocument: LyricsDocument
    var translation: LyricTranslation
    var runtimeFeatureFlags = RuntimeFeatureFlags.architectureDefault
    var showsTranslation: Bool
    var preferredTranslationLanguage: String
    var overlayWidthPreset: OverlayWidthPreset
    var reduceHiddenMemoryUsage: Bool

    private let snapshotBuilder = LyricsOverlaySnapshotBuilder()

    init(userDefaults: UserDefaults = .standard) {
        playerState = MockMusicAppBridge.previewState
        lyricsDocument = MockLyricsProvider.previewDocument

        let language = userDefaults.string(forKey: "preferredTranslationLanguage") ?? "French"
        preferredTranslationLanguage = language
        translation = MockTranslationProvider.previewTranslation(targetLanguage: language)
        showsTranslation = userDefaults.object(forKey: "showTranslation") as? Bool ?? true
        overlayWidthPreset = OverlayWidthPreset(
            rawValue: userDefaults.string(forKey: "overlayWidthPreset") ?? OverlayWidthPreset.medium.rawValue
        ) ?? .medium
        reduceHiddenMemoryUsage = userDefaults.object(forKey: "reduceHiddenMemoryUsage") as? Bool ?? true
    }

    var overlaySnapshot: LyricsOverlaySnapshot {
        snapshotBuilder.makeSnapshot(
            contentState: overlayContentState,
            playerState: playerState,
            lyricsDocument: lyricsDocument,
            translation: translation,
            showsTranslation: showsTranslation,
            widthPreset: overlayWidthPreset
        )
    }

    func applyPreferences(
        showsTranslation: Bool,
        preferredTranslationLanguage: String,
        overlayWidthPreset: OverlayWidthPreset,
        reduceHiddenMemoryUsage: Bool
    ) {
        self.showsTranslation = showsTranslation
        self.preferredTranslationLanguage = preferredTranslationLanguage
        self.overlayWidthPreset = overlayWidthPreset
        self.reduceHiddenMemoryUsage = reduceHiddenMemoryUsage
        translation = MockTranslationProvider.previewTranslation(targetLanguage: preferredTranslationLanguage)

        AppTelemetry.settings.info(
            "Preferences applied translation=\(showsTranslation) language=\(preferredTranslationLanguage, privacy: .public) width=\(overlayWidthPreset.rawValue, privacy: .public) reduceHiddenMemory=\(reduceHiddenMemoryUsage)"
        )
    }

    func updatePlayerState(_ playerState: PlayerState) {
        self.playerState = playerState
    }

    func setProviderRuntimeState(_ state: ProviderRuntimeState) {
        providerRuntimeState = state
        AppTelemetry.performance.info("Provider runtime state set to \(state.displayName, privacy: .public)")
    }

    func applyLyricsDocument(_ document: LyricsDocument) {
        lyricsDocument = document
    }

    func applyTranslation(_ translation: LyricTranslation) {
        self.translation = translation
    }

    func clearTranslation() {
        translation = LyricTranslation(targetLanguage: preferredTranslationLanguage, lines: [])
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
        playerState = MockMusicAppBridge.previewState
        overlayContentState = .ready
        AppTelemetry.performance.info("Mock playback snapshot reset")
    }

    func setOverlayContentState(_ state: OverlayContentState) {
        overlayContentState = state
        AppTelemetry.performance.info("Mock overlay state set to \(state.displayName, privacy: .public)")
    }
}
