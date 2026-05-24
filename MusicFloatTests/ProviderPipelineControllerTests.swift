import XCTest
@testable import MusicFloat

@MainActor
final class ProviderPipelineControllerTests: XCTestCase {
    func testLiveTransientNilTrackPreservesReadyLyricsState() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveTransientNilTrack.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let document = LyricsDocument(
            source: .mock,
            lines: [LyricLine(id: 0, text: "Stay here", startTime: 40)],
            isTimed: true
        )
        appState.applyLyricsDocument(document)
        appState.applyProviderReady()
        appState.updatePlayerState(PlayerState(
            playbackStatus: .paused,
            track: nil,
            elapsedTime: 0,
            updatedAt: Date()
        ))

        let lyricsProvider = RecordingLyricsProvider()
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: RecordingTranslationProvider()
        )

        controller.refreshOverlayContentForLiveTrack(appState: appState)

        XCTAssertEqual(appState.overlayContentState, .ready)
        XCTAssertEqual(appState.providerRuntimeState, .ready)
        XCTAssertEqual(appState.lyricsDocument, document)
        XCTAssertEqual(lyricsProvider.requestedTrackIDs, [])
    }

    private final class RecordingLyricsProvider: LyricsProvider {
        let displayName = "Recording lyrics provider"
        private(set) var requestedTrackIDs: [String] = []

        func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
            requestedTrackIDs.append(track.id)
            return .unavailable
        }
    }

    private struct RecordingTranslationProvider: TranslationProvider {
        let displayName = "Recording translation provider"

        func translation(for document: LyricsDocument, targetLanguage: String) async -> TranslationProviderResult {
            .unavailable
        }
    }
}
