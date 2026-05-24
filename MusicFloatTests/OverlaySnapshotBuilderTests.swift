import XCTest
@testable import MusicFloat

final class OverlaySnapshotBuilderTests: XCTestCase {
    @MainActor
    func testAppStateEffectiveElapsedUsesLiveClockWhenPlayerSnapshotIsStale() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.effectiveElapsed.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        var staleState = MockMusicAppBridge.previewState
        staleState.elapsedTime = 10
        appState.updatePlayerState(staleState)
        appState.setMockPreviewRunning(true)
        appState.updateLiveElapsedTime(42)

        XCTAssertEqual(appState.playerState.elapsedTime, 10)
        XCTAssertEqual(appState.effectiveElapsedTime, 42)
    }

    @MainActor
    func testOverlaySnapshotUsesEffectiveElapsedTime() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.overlayEffectiveElapsed.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        var staleState = MockMusicAppBridge.previewState
        staleState.elapsedTime = 10
        appState.updatePlayerState(staleState)
        appState.setMockPreviewRunning(true)
        appState.updateLiveElapsedTime(42)

        XCTAssertEqual(appState.overlaySnapshot.lyricText, "Translation follows, soft and native")
    }

    @MainActor
    func testReadySnapshotUsesActiveLyricAndTranslation() {
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: MockMusicAppBridge.previewState,
            lyricsDocument: MockLyricsProvider.previewDocument,
            translation: MockTranslationProvider.previewTranslation(targetLanguage: "French"),
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.contentState, .ready)
        XCTAssertEqual(snapshot.lyricText, "Translation follows, soft and native")
        XCTAssertEqual(snapshot.translationText, "La traduction suit, douce et native")
        XCTAssertEqual(snapshot.widthPreset, .medium)
    }

    @MainActor
    func testUnavailableSnapshotDoesNotPretendLyricsAreReady() {
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .unavailable,
            playerState: .disconnected,
            lyricsDocument: MockLyricsProvider.previewDocument,
            translation: MockTranslationProvider.previewTranslation(targetLanguage: "French"),
            showsTranslation: true,
            widthPreset: .compact
        )

        XCTAssertEqual(snapshot.contentState, .unavailable)
        XCTAssertEqual(snapshot.lyricText, "Lyrics unavailable for this track")
        XCTAssertEqual(snapshot.translationText, "Translation will wait for lyrics")
    }
}
