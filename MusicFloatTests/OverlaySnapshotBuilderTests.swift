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

    @MainActor
    func testActiveSyllableSelectionUsesEndTimeWindow() {
        let line = LyricLine(
            id: 0,
            text: "hello",
            startTime: 0,
            syllables: [
                LyricSyllable(text: "hel", startTime: 1, endTime: 1.5),
                LyricSyllable(text: "lo", startTime: 1.5, endTime: 2)
            ]
        )

        XCTAssertEqual(LyricsOverlaySnapshotBuilder.activeSyllableIndex(in: line, at: 1.25), 0)
        XCTAssertEqual(LyricsOverlaySnapshotBuilder.activeSyllableIndex(in: line, at: 1.75), 1)
    }

    @MainActor
    func testActiveSyllableFallsBackToLatestStartedSyllable() {
        let line = LyricLine(
            id: 0,
            text: "hello",
            startTime: 0,
            syllables: [
                LyricSyllable(text: "hel", startTime: 1, endTime: 1.5),
                LyricSyllable(text: "lo", startTime: 1.5, endTime: 2)
            ]
        )

        XCTAssertNil(LyricsOverlaySnapshotBuilder.activeSyllableIndex(in: line, at: 0.75))
        XCTAssertEqual(LyricsOverlaySnapshotBuilder.activeSyllableIndex(in: line, at: 2.5), 1)
    }

    @MainActor
    func testSnapshotKeepsPlainLyricFallbackWhenSyllablesAreEmpty() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [
                LyricLine(id: 0, text: "Plain timed lyric", startTime: 4, syllables: [])
            ],
            isTimed: true
        )
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 4.25),
            lyricsDocument: document,
            translation: LyricTranslation(targetLanguage: "French", lines: []),
            showsTranslation: false,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.lyricText, "Plain timed lyric")
        XCTAssertEqual(snapshot.activeLine?.syllables, [])
    }

    @MainActor
    func testUntimedDocumentRendersFirstPlainLine() {
        let document = LyricsDocument(
            source: .musicApp,
            lines: [
                LyricLine(id: 0, text: "First untimed line", startTime: nil),
                LyricLine(id: 1, text: "Second untimed line", startTime: nil)
            ],
            isTimed: false
        )
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 120),
            lyricsDocument: document,
            translation: LyricTranslation(targetLanguage: "French", lines: []),
            showsTranslation: false,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.lyricText, "First untimed line")
        XCTAssertEqual(snapshot.activeLine?.id, 0)
    }

    @MainActor
    func testSnapshotEffectiveTimeRespectsUserAndDocumentOffsets() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(
                    id: 0,
                    text: "Offset karaoke",
                    startTime: 8,
                    syllables: [
                        LyricSyllable(text: "Offset ", startTime: 8, endTime: 8.5),
                        LyricSyllable(text: "karaoke", startTime: 8.5, endTime: 9)
                    ]
                )
            ],
            isTimed: true,
            offsetCorrection: 2
        )
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 5.75),
            lyricsDocument: document,
            translation: LyricTranslation(targetLanguage: "French", lines: []),
            showsTranslation: false,
            widthPreset: .medium,
            lyricOffsetSeconds: 0.75
        )

        XCTAssertEqual(snapshot.activeLine?.id, 0)
        XCTAssertEqual(snapshot.effectiveLyricTime, 8.5)
        XCTAssertEqual(
            LyricsOverlaySnapshotBuilder.activeSyllableIndex(in: snapshot.activeLine!, at: snapshot.effectiveLyricTime),
            1
        )
    }

    @MainActor
    private func playerState(elapsedTime: TimeInterval) -> PlayerState {
        var state = MockMusicAppBridge.previewState
        state.elapsedTime = elapsedTime
        return state
    }
}
