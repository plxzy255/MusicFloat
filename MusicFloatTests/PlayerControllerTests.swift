import AppKit
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

    @MainActor
    func testVolumeCommandClampsBeforeBridge() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.volumeClamp.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let bridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)

        await controller.performLivePlaybackCommand(.setVolume(140), appState: appState)

        XCTAssertEqual(bridge.commands, [.setVolume(100)])
        XCTAssertEqual(appState.musicVolume, 100)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testPlaybackCommandIgnoredInDemoMode() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.demoPlaybackCommand.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let bridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)

        await controller.performLivePlaybackCommand(.playPause, appState: appState, isDemoMode: true)

        XCTAssertTrue(bridge.commands.isEmpty)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testPlayPauseCommandRefreshesPlayerState() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.playPauseRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let refreshedState = PlayerState(
            playbackStatus: .paused,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 43,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)
        bridge.states = [refreshedState]

        await controller.performLivePlaybackCommand(.playPause, appState: appState)

        XCTAssertEqual(bridge.commands, [.playPause])
        XCTAssertEqual(appState.playerState, refreshedState)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testNextTrackCommandRefreshesStateAndClearsArtwork() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.nextTrackRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let firstTrack = MockMusicAppBridge.previewTrack
        let nextTrack = NowPlayingTrack(
            id: "next-track",
            title: "Next",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let firstState = PlayerState(
            playbackStatus: .playing,
            track: firstTrack,
            elapsedTime: 12,
            updatedAt: Date()
        )
        let nextState = PlayerState(
            playbackStatus: .playing,
            track: nextTrack,
            elapsedTime: 0,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [firstState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )
        var changedTrack: NowPlayingTrack?

        controller.startLiveAppleMusic(appState: appState) { track in
            changedTrack = track
        }
        await waitForCurrentStateCall(on: bridge)
        changedTrack = nil
        appState.applyNowPlayingArtwork(NSImage(size: NSSize(width: 8, height: 8)), forTrackID: firstTrack.id)
        bridge.states = [firstState, nextState]

        await controller.performLivePlaybackCommand(.nextTrack, appState: appState)

        XCTAssertEqual(bridge.commands, [.nextTrack])
        XCTAssertEqual(appState.playerState, nextState)
        XCTAssertNil(appState.nowPlayingArtwork)
        XCTAssertEqual(changedTrack?.id, nextTrack.id)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testSeekCommandClampsToTrackDurationAndRefreshesState() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.seekClamp.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let track = NowPlayingTrack(
            id: "seek-track",
            title: "Seek",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let initialState = PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 12,
            updatedAt: Date()
        )
        let seekState = PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 180,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [initialState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)
        bridge.states = [seekState]

        await controller.performLivePlaybackCommand(.seek(500), appState: appState)

        XCTAssertEqual(bridge.commands, [.seek(180)])
        XCTAssertEqual(appState.playerState, seekState)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    private func waitForCurrentStateCall(on bridge: RecordingMusicBridge) async {
        for _ in 0..<20 {
            if bridge.currentStateCallCount > 0 {
                return
            }
            await Task.yield()
        }
    }
}

@MainActor
private final class RecordingMusicBridge: MusicAppBridge {
    let displayName = "Recording music bridge"
    var states: [PlayerState]
    var commands: [MusicPlaybackCommand] = []
    var commandResult: MusicPlaybackCommandResult = .succeeded
    var reportedVolume: Int?
    private(set) var currentStateCallCount = 0

    init(states: [PlayerState]) {
        self.states = states
    }

    func currentState() async -> PlayerState {
        currentStateCallCount += 1
        guard !states.isEmpty else {
            return .disconnected
        }
        return states.removeFirst()
    }

    func perform(_ command: MusicPlaybackCommand) async -> MusicPlaybackCommandResult {
        commands.append(command)
        return commandResult
    }

    func currentVolume() async -> Int? {
        reportedVolume
    }
}
