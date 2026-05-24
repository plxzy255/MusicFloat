import XCTest
@testable import MusicFloat

final class PlayerControllerTests: XCTestCase {
    @MainActor
    func testRestartLiveTickSeedsFromEffectiveElapsedTime() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveTickSeed.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.setLiveModeRunning(true)

        var staleSnapshot = MockMusicAppBridge.previewState
        staleSnapshot.elapsedTime = 10
        appState.updatePlayerState(staleSnapshot)
        appState.updateLiveElapsedTime(58)

        XCTAssertEqual(PlayerController.liveTickInitialElapsed(appState: appState), 58)
    }
}
