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
        let referenceDate = Date(timeIntervalSinceReferenceDate: 123)
        var playerState = MockMusicAppBridge.previewState
        playerState.updatedAt = referenceDate
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState,
            lyricsDocument: MockLyricsProvider.previewDocument,
            translation: MockTranslationProvider.previewTranslation(targetLanguageIdentifier: "fr"),
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.contentState, .ready)
        XCTAssertEqual(snapshot.lyricText, "Translation follows, soft and native")
        XCTAssertEqual(snapshot.translationText, "La traduction suit, douce et native")
        XCTAssertEqual(snapshot.attributionText, "Mock lyrics - \(languageName("en")) to \(languageName("fr"))")
        XCTAssertEqual(snapshot.widthPreset, .medium)
        XCTAssertEqual(snapshot.lyricClockReferenceDate, referenceDate)
        XCTAssertTrue(snapshot.isLyricClockRunning)
    }

    @MainActor
    func testPausedSnapshotDoesNotRunLyricClock() {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 456)
        let state = PlayerState(
            playbackStatus: .paused,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 42,
            updatedAt: referenceDate
        )

        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: state,
            lyricsDocument: MockLyricsProvider.previewDocument,
            translation: MockTranslationProvider.previewTranslation(targetLanguageIdentifier: "fr"),
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.lyricClockReferenceDate, referenceDate)
        XCTAssertFalse(snapshot.isLyricClockRunning)
    }

    @MainActor
    func testReadySnapshotBuildsPreviousActiveNextLyricWindow() {
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 11),
            lyricsDocument: timedDocument(),
            translation: lineTranslations(),
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.lyricWindow.map(\.id), [0, 1, 2])
        XCTAssertEqual(snapshot.lyricWindow.map(\.role), [.previous, .active, .next])
        XCTAssertEqual(snapshot.lyricWindow.map(\.translationText), [nil, "Middle translated", nil])
    }

    @MainActor
    func testReadySnapshotShowsNextLineBeforeFirstTimedLyricStarts() {
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 2),
            lyricsDocument: timedDocument(),
            translation: lineTranslations(),
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertNil(snapshot.activeLine)
        XCTAssertEqual(snapshot.lyricWindow.map(\.id), [0])
        XCTAssertEqual(snapshot.lyricWindow.map(\.role), [.next])
        XCTAssertNil(snapshot.lyricWindow.first?.translationText)
    }

    @MainActor
    func testReadySnapshotBuildsPreviousActiveWindowAtLastLine() {
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 21),
            lyricsDocument: timedDocument(),
            translation: lineTranslations(),
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.lyricWindow.map(\.id), [1, 2])
        XCTAssertEqual(snapshot.lyricWindow.map(\.role), [.previous, .active])
        XCTAssertEqual(snapshot.lyricWindow.map(\.translationText), [nil, "Last translated"])
    }

    @MainActor
    func testUntimedDocumentBuildsEstimatedPreviousActiveLyricWindow() {
        let document = LyricsDocument(
            source: .musicApp,
            lines: [
                LyricLine(id: 10, text: "First untimed line", startTime: nil),
                LyricLine(id: 11, text: "Second untimed line", startTime: nil)
            ],
            isTimed: false
        )
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 120),
            lyricsDocument: document,
            translation: LyricTranslation(
                targetLanguageIdentifier: "fr",
                sourceLanguageIdentifier: "en",
                lines: [
                    TranslatedLyricLine(id: 0, sourceLineID: 10, text: "First translated"),
                    TranslatedLyricLine(id: 1, sourceLineID: 11, text: "Second translated")
                ]
            ),
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.lyricWindow.map(\.id), [10, 11])
        XCTAssertEqual(snapshot.lyricWindow.map(\.role), [.previous, .active])
        XCTAssertEqual(snapshot.lyricWindow.map(\.translationText), [nil, "Second translated"])
    }

    @MainActor
    func testLyricWindowUsesStableLineIDsAcrossRoleChanges() {
        let document = timedDocument()
        let translation = lineTranslations()
        let before = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 2),
            lyricsDocument: document,
            translation: translation,
            showsTranslation: true,
            widthPreset: .medium
        )
        let during = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState(elapsedTime: 11),
            lyricsDocument: document,
            translation: translation,
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(before.lyricWindow.first?.id, 0)
        XCTAssertEqual(before.lyricWindow.first?.role, .next)
        XCTAssertEqual(during.lyricWindow.first?.id, 0)
        XCTAssertEqual(during.lyricWindow.first?.role, .previous)
    }

    @MainActor
    func testReadySnapshotAttributionShowsTranslatedSourceAndTarget() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [LyricLine(id: 0, text: "Привет", startTime: 0)],
            isTimed: true,
            sourceLanguageIdentifier: "ru"
        )
        let translation = LyricTranslation(
            targetLanguageIdentifier: "en",
            sourceLanguageIdentifier: "ru",
            lines: [TranslatedLyricLine(id: 0, sourceLineID: 0, text: "Hello")]
        )
        let playerState = PlayerState(
            playbackStatus: .playing,
            track: NowPlayingTrack(
                id: "track",
                title: "Track",
                artist: "Artist",
                album: "",
                duration: 120,
                providerName: "Apple Music"
            ),
            elapsedTime: 0,
            updatedAt: Date()
        )

        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .ready,
            playerState: playerState,
            lyricsDocument: document,
            translation: translation,
            showsTranslation: true,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.attributionText, "Apple Music - \(languageName("ru")) to \(languageName("en"))")
    }

    @MainActor
    func testUnavailableSnapshotDoesNotPretendLyricsAreReady() {
        let snapshot = LyricsOverlaySnapshotBuilder().makeSnapshot(
            contentState: .unavailable,
            playerState: .disconnected,
            lyricsDocument: MockLyricsProvider.previewDocument,
            translation: MockTranslationProvider.previewTranslation(targetLanguageIdentifier: "fr"),
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
    func testTimedLineProgressUsesWeightedSyllableTiming() throws {
        let line = LyricLine(
            id: 0,
            text: "One two",
            startTime: 10,
            syllables: [
                LyricSyllable(text: "One ", startTime: 10, endTime: 11),
                LyricSyllable(text: "two", startTime: 11, endTime: 13)
            ]
        )

        XCTAssertEqual(LyricsOverlaySnapshotBuilder.timedLineProgress(in: line, at: 9.5), 0)
        XCTAssertEqual(LyricsOverlaySnapshotBuilder.timedLineProgress(in: line, at: 14), 1)
        let activeProgress = try XCTUnwrap(LyricsOverlaySnapshotBuilder.timedLineProgress(in: line, at: 11.5))
        XCTAssertEqual(activeProgress, 4.75 / 7.0, accuracy: 0.0001)
    }

    @MainActor
    func testTimedLineProgressPrefersSyllableClockOverLinearLineTiming() throws {
        let line = LyricLine(
            id: 0,
            text: "Quick slow",
            startTime: 0,
            endTime: 4,
            syllables: [
                LyricSyllable(text: "Quick ", startTime: 0, endTime: 0.5),
                LyricSyllable(text: "slow", startTime: 0.5, endTime: 4)
            ]
        )

        let progress = try XCTUnwrap(LyricsOverlaySnapshotBuilder.timedLineProgress(in: line, at: 1))

        XCTAssertGreaterThan(progress, 0.60)
        XCTAssertEqual(progress, (6.0 + (4.0 * (0.5 / 3.5))) / 10.0, accuracy: 0.0001)
    }

    @MainActor
    func testTimedLineProgressFallsBackToLineTiming() {
        let line = LyricLine(
            id: 0,
            text: "Line timed lyric",
            startTime: 10,
            endTime: 14
        )

        XCTAssertEqual(LyricsOverlaySnapshotBuilder.timedLineProgress(in: line, at: 12), 0.5)
    }

    @MainActor
    func testKaraokeProgressRendersOnlyForSyllableTimedLines() {
        let lineTimedOnly = LyricLine(
            id: 0,
            text: "Line timed lyric",
            startTime: 10,
            endTime: 14
        )
        let syllableTimed = LyricLine(
            id: 1,
            text: "Word timed lyric",
            startTime: 10,
            endTime: 14,
            syllables: [
                LyricSyllable(text: "Word ", startTime: 10, endTime: 11),
                LyricSyllable(text: "timed", startTime: 11, endTime: 12)
            ]
        )

        XCTAssertFalse(LyricsOverlaySnapshotBuilder.shouldRenderKaraokeProgress(for: lineTimedOnly))
        XCTAssertTrue(LyricsOverlaySnapshotBuilder.shouldRenderKaraokeProgress(for: syllableTimed))
    }

    @MainActor
    func testKaraokeProgressDoesNotRenderForUntimedLinesWithSyllables() {
        let untimedWithSyllables = LyricLine(
            id: 0,
            text: "Untimed word data",
            startTime: nil,
            syllables: [
                LyricSyllable(text: "Untimed ", startTime: 1, endTime: 2),
                LyricSyllable(text: "word", startTime: 2, endTime: 3)
            ]
        )

        XCTAssertFalse(LyricsOverlaySnapshotBuilder.shouldRenderKaraokeProgress(for: untimedWithSyllables))
        XCTAssertNil(LyricsOverlaySnapshotBuilder.timedLineProgress(in: untimedWithSyllables, at: 2.5))
    }

    @MainActor
    func testTimedLineProgressReturnsNilWithoutTiming() {
        let line = LyricLine(id: 0, text: "Plain lyric", startTime: nil)

        XCTAssertNil(LyricsOverlaySnapshotBuilder.timedLineProgress(in: line, at: 12))
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
            translation: LyricTranslation(targetLanguageIdentifier: "fr", sourceLanguageIdentifier: "en", lines: []),
            showsTranslation: false,
            widthPreset: .medium
        )

        XCTAssertEqual(snapshot.lyricText, "Plain timed lyric")
        XCTAssertEqual(snapshot.activeLine?.syllables, [])
    }

    @MainActor
    func testUntimedDocumentRendersFirstPlainLineEarlyInTrack() {
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
            playerState: playerState(elapsedTime: 10),
            lyricsDocument: document,
            translation: LyricTranslation(targetLanguageIdentifier: "fr", sourceLanguageIdentifier: "en", lines: []),
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
            translation: LyricTranslation(targetLanguageIdentifier: "fr", sourceLanguageIdentifier: "en", lines: []),
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
    func testLyricsDocumentOffsetPreservesSourceLanguage() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [LyricLine(id: 0, text: "Language stays", startTime: 1)],
            isTimed: true,
            sourceLanguageIdentifier: "en"
        )

        XCTAssertEqual(document.withOffsetCorrection(1.5).sourceLanguageIdentifier, "en")
    }

    @MainActor
    private func playerState(elapsedTime: TimeInterval) -> PlayerState {
        var state = MockMusicAppBridge.previewState
        state.elapsedTime = elapsedTime
        return state
    }

    private func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    @MainActor
    private func timedDocument() -> LyricsDocument {
        LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(id: 0, text: "First timed line", startTime: 5),
                LyricLine(id: 1, text: "Middle timed line", startTime: 10),
                LyricLine(id: 2, text: "Last timed line", startTime: 20)
            ],
            isTimed: true,
            sourceLanguageIdentifier: "en"
        )
    }

    @MainActor
    private func lineTranslations() -> LyricTranslation {
        LyricTranslation(
            targetLanguageIdentifier: "fr",
            sourceLanguageIdentifier: "en",
            lines: [
                TranslatedLyricLine(id: 0, sourceLineID: 0, text: "First translated"),
                TranslatedLyricLine(id: 1, sourceLineID: 1, text: "Middle translated"),
                TranslatedLyricLine(id: 2, sourceLineID: 2, text: "Last translated")
            ]
        )
    }
}
