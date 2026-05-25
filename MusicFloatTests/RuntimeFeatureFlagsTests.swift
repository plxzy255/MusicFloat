import XCTest
@testable import MusicFloat

final class RuntimeFeatureFlagsTests: XCTestCase {
    func testArchitectureDefaultsStayMockOnlyAndIdleSafe() {
        let flags = RuntimeFeatureFlags.architectureDefault

        XCTAssertEqual(flags.playerBridgeMode, .mock)
        XCTAssertEqual(flags.lyricsProviderMode, .mock)
        XCTAssertEqual(flags.translationProviderMode, .mock)
        XCTAssertFalse(flags.allowsHiddenProviderRefresh)
    }

    func testLiveAppleMusicFlagsUsePublicProvidersWithoutHiddenRefresh() {
        let flags = RuntimeFeatureFlags.liveAppleMusic

        XCTAssertEqual(flags.playerBridgeMode, .publicApple)
        XCTAssertEqual(flags.lyricsProviderMode, .publicApple)
        XCTAssertEqual(flags.translationProviderMode, .publicApple)
        XCTAssertFalse(flags.allowsHiddenProviderRefresh)
    }

    func testTranslationProviderDisplayNamesMatchAdapterModes() {
        XCTAssertEqual(RuntimeAdapterMode.mock.translationProviderDisplayName, "Mock translation provider")
        XCTAssertEqual(RuntimeAdapterMode.publicApple.translationProviderDisplayName, "Apple on-device translation")
        XCTAssertEqual(
            RuntimeAdapterMode.experimental.translationProviderDisplayName,
            "Experimental translation provider placeholder"
        )
        XCTAssertEqual(RuntimeAdapterMode.disabled.translationProviderDisplayName, "Disabled translation provider")
    }
}
