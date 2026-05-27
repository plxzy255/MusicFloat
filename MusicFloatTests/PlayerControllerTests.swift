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
    func testHiddenLiveElapsedResumesFromWallClock() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveWallClockResume.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.setLiveModeRunning(true)
        let referenceDate = Date(timeIntervalSince1970: 1_000)
        var snapshot = MockMusicAppBridge.previewState
        snapshot.elapsedTime = 10
        snapshot.updatedAt = referenceDate
        appState.updatePlayerState(snapshot)

        appState.resumeLiveElapsedTimeFromWallClock(
            now: referenceDate.addingTimeInterval(15)
        )

        XCTAssertEqual(appState.effectiveElapsedTime, 25, accuracy: 0.001)
    }

    @MainActor
    func testHiddenLiveElapsedResumeClampsToTrackDuration() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveWallClockResumeClamp.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.setLiveModeRunning(true)
        let referenceDate = Date(timeIntervalSince1970: 1_000)
        let track = NowPlayingTrack(
            id: "short-track",
            title: "Short",
            artist: "MusicFloat",
            album: "Tests",
            duration: 20,
            providerName: "Test"
        )
        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 18,
            updatedAt: referenceDate
        ))

        appState.resumeLiveElapsedTimeFromWallClock(
            now: referenceDate.addingTimeInterval(15)
        )

        XCTAssertEqual(appState.effectiveElapsedTime, 20, accuracy: 0.001)
    }

    @MainActor
    func testLiveTickIntervalIgnoresSyllableBoundaries() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(
                    id: 0,
                    text: "Dense syllables",
                    startTime: 0,
                    syllables: [
                        LyricSyllable(text: "Dense ", startTime: 0.1, endTime: 0.2),
                        LyricSyllable(text: "syllables", startTime: 0.2, endTime: 0.3)
                    ]
                ),
                LyricLine(id: 1, text: "Next line", startTime: 8)
            ],
            isTimed: true
        )

        let interval = PlayerController.liveTickInterval(
            currentElapsed: 0,
            lyricsDocument: document,
            lyricOffsetSeconds: 0,
            duration: 120
        )

        XCTAssertEqual(interval, 1.0, accuracy: 0.0001)
    }

    @MainActor
    func testLiveTickIntervalStillWakesForLineBoundary() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(id: 0, text: "Current line", startTime: 0),
                LyricLine(id: 1, text: "Soon", startTime: 0.35)
            ],
            isTimed: true
        )

        let interval = PlayerController.liveTickInterval(
            currentElapsed: 0,
            lyricsDocument: document,
            lyricOffsetSeconds: 0,
            duration: 120
        )

        XCTAssertEqual(interval, 0.35, accuracy: 0.0001)
    }

    @MainActor
    func testPreviewRefreshUsesTrackDurationForUntimedLyrics() {
        let controller = PlayerController(bridge: MockMusicAppBridge())
        let track = NowPlayingTrack(
            id: "plain-preview-track",
            title: "Plain",
            artist: "Artist",
            album: "Album",
            duration: 90,
            providerName: "Test"
        )
        let state = PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 10,
            updatedAt: Date()
        )
        let document = LyricsDocument(
            source: .musicApp,
            lines: [
                LyricLine(id: 0, text: "First sentence", startTime: nil),
                LyricLine(id: 1, text: "Second sentence", startTime: nil),
                LyricLine(id: 2, text: "Third sentence", startTime: nil)
            ],
            isTimed: false
        )

        let interval = controller.nextRefreshInterval(
            currentState: state,
            lyricsDocument: document
        )

        XCTAssertEqual(interval, 20, accuracy: 0.001)
    }

    @MainActor
    func testLiveResyncDecisionSnapsSmallDriftWithoutSeek() {
        let snapshot = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 10.4,
            updatedAt: Date()
        )

        let decision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: snapshot
        )

        XCTAssertEqual(decision.snapshotDelta, 0.4, accuracy: 0.0001)
        XCTAssertTrue(decision.isSameTrack)
        XCTAssertTrue(decision.shouldSnap)
        XCTAssertFalse(decision.isSeek)
    }

    @MainActor
    func testLiveResyncDecisionClassifiesLargeSameTrackJumpAsSeek() {
        let snapshot = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 13,
            updatedAt: Date()
        )

        let decision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: snapshot
        )

        XCTAssertTrue(decision.shouldSnap)
        XCTAssertTrue(decision.isSeek)
    }

    @MainActor
    func testLiveResyncDecisionDoesNotSnapDifferentTrackOrMissingTrack() {
        let differentTrack = NowPlayingTrack(
            id: "different-track",
            title: "Different",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let differentSnapshot = PlayerState(
            playbackStatus: .playing,
            track: differentTrack,
            elapsedTime: 30,
            updatedAt: Date()
        )
        let missingSnapshot = PlayerState(
            playbackStatus: .playing,
            track: nil,
            elapsedTime: 30,
            updatedAt: Date()
        )

        let differentDecision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: differentSnapshot
        )
        let missingDecision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: missingSnapshot
        )

        XCTAssertFalse(differentDecision.shouldSnap)
        XCTAssertFalse(differentDecision.isSeek)
        XCTAssertFalse(missingDecision.shouldSnap)
        XCTAssertFalse(missingDecision.isSeek)
    }

    @MainActor
    func testLiveResyncDecisionTreatsSeekThresholdAsNonSeekSnapBoundary() {
        let snapshot = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 12,
            updatedAt: Date()
        )

        let decision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: snapshot
        )

        XCTAssertTrue(decision.shouldSnap)
        XCTAssertFalse(decision.isSeek)
    }

    @MainActor
    func testLiveResyncFailureIntervalBacksOffAfterMissingSnapshots() {
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 0), 1)
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 1), 3)
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 3), 7)
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 20), 10)
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
    func testOverlayRevealRefreshesAuthoritativeLiveState() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.overlayRevealRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let initialState = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 10,
            updatedAt: Date()
        )
        let refreshedState = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 45,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [initialState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)
        appState.isOverlayVisible = false
        controller.overlayVisibilityChanged(false, appState: appState)
        bridge.states = [refreshedState, refreshedState]
        appState.isOverlayVisible = true

        controller.overlayVisibilityChanged(true, appState: appState)
        try await waitUntil { appState.playerState.elapsedTime == 45 }

        XCTAssertEqual(appState.playerState, refreshedState)
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
        XCTFail("Timed out waiting for bridge.currentState() to be called")
    }

    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
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
