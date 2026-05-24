import XCTest
@testable import MusicFloat

final class RuntimeAdapterFactoryTests: XCTestCase {
    @MainActor
    func testArchitectureDefaultFactoryUsesMockAdapters() {
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)

        XCTAssertEqual(adapters.musicBridge.displayName, "Mock Music bridge")
        XCTAssertEqual(adapters.lyricsProvider.displayName, "Mock lyrics provider")
        XCTAssertEqual(adapters.translationProvider.displayName, "Mock translation provider")
    }

    @MainActor
    func testArchitectureDefaultMockPreviewUsesMockProviderPayloads() async {
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)

        let lyricsResult = await adapters.lyricsProvider.lyrics(for: MockMusicAppBridge.previewTrack)
        let translationResult = await adapters.translationProvider.translation(
            for: MockLyricsProvider.previewDocument,
            targetLanguage: "French"
        )

        XCTAssertEqual(lyricsResult, .available(MockLyricsProvider.previewDocument))
        XCTAssertEqual(
            translationResult,
            .available(MockTranslationProvider.previewTranslation(targetLanguage: "French"))
        )
    }

    @MainActor
    func testLiveAppleMusicFactoryUsesPublicAdapters() {
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .liveAppleMusic)

        XCTAssertEqual(adapters.musicBridge.displayName, "Public Apple API bridge")
        XCTAssertEqual(adapters.lyricsProvider.displayName, "Public lyrics provider")
        XCTAssertEqual(adapters.translationProvider.displayName, "Public translation provider placeholder")
    }
}
