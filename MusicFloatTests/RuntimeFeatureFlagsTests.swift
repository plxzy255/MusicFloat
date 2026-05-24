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
}
