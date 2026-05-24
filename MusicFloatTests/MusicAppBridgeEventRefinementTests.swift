import XCTest
@testable import MusicFloat

@MainActor
final class MusicAppBridgeEventRefinementTests: XCTestCase {
    func testPausedSameTrackEventWithoutPositionPreservesElapsed() {
        let now = Date()
        let previous = PlayerState(
            playbackStatus: .playing,
            track: Self.track(id: "track-1"),
            elapsedTime: 64,
            updatedAt: now.addingTimeInterval(-1)
        )
        let event = PlayerState(
            playbackStatus: .paused,
            track: Self.track(id: "track-1"),
            elapsedTime: 0,
            updatedAt: now
        )

        let refined = PublicAppleMusicAppBridge.refinePlayerInfoEvent(
            event: event,
            lastEmittedState: previous,
            lastEmittedAt: now.addingTimeInterval(-1),
            snapshot: nil,
            now: now
        )

        XCTAssertEqual(refined.state.playbackStatus, .paused)
        XCTAssertEqual(refined.state.track?.id, "track-1")
        XCTAssertEqual(refined.state.elapsedTime, 64)
        XCTAssertFalse(refined.refineSucceeded)
    }

    func testPausedTitleEmptyPlayerInfoPreservesPreviousTrackUntilConfirmedDisconnected() {
        let now = Date()
        let previous = PlayerState(
            playbackStatus: .playing,
            track: Self.track(id: "track-1"),
            elapsedTime: 72,
            updatedAt: now.addingTimeInterval(-2)
        )
        let playerInfo = AppleMusicEventListener.makeEvent(userInfo: [
            "Player State": "Paused",
            "Name": "",
            "Artist": "",
            "Album": "",
            "Total Time": 0
        ])!

        let refined = PublicAppleMusicAppBridge.refinePlayerInfoEvent(
            event: playerInfo.state,
            lastEmittedState: previous,
            lastEmittedAt: now.addingTimeInterval(-2),
            snapshot: nil,
            now: now
        )

        XCTAssertEqual(playerInfo.state.playbackStatus, .paused)
        XCTAssertNil(playerInfo.state.track)
        XCTAssertEqual(refined.state.playbackStatus, .paused)
        XCTAssertEqual(refined.state.track?.id, "track-1")
        XCTAssertEqual(refined.state.elapsedTime, 72)
    }

    func testStoppedTitleEmptyPlayerInfoUsesConfirmedDisconnectedSnapshot() {
        let now = Date()
        let previous = PlayerState(
            playbackStatus: .playing,
            track: Self.track(id: "track-1"),
            elapsedTime: 72,
            updatedAt: now.addingTimeInterval(-2)
        )
        let event = PlayerState(
            playbackStatus: .stopped,
            track: nil,
            elapsedTime: 0,
            updatedAt: now
        )

        let refined = PublicAppleMusicAppBridge.refinePlayerInfoEvent(
            event: event,
            lastEmittedState: previous,
            lastEmittedAt: now.addingTimeInterval(-2),
            snapshot: .disconnected,
            now: now
        )

        XCTAssertEqual(refined.state.playbackStatus, .stopped)
        XCTAssertNil(refined.state.track)
        XCTAssertEqual(refined.state.elapsedTime, 0)
        XCTAssertTrue(refined.refineSucceeded)
    }

    func testResumeAfterPauseWithoutSnapshotStartsFromPreservedElapsed() {
        let lastEmittedAt = Date()
        let now = lastEmittedAt.addingTimeInterval(1.5)
        let previous = PlayerState(
            playbackStatus: .paused,
            track: Self.track(id: "track-1"),
            elapsedTime: 81,
            updatedAt: lastEmittedAt
        )
        let event = PlayerState(
            playbackStatus: .playing,
            track: Self.track(id: "track-1"),
            elapsedTime: 0,
            updatedAt: now
        )

        let refined = PublicAppleMusicAppBridge.refinePlayerInfoEvent(
            event: event,
            lastEmittedState: previous,
            lastEmittedAt: lastEmittedAt,
            snapshot: nil,
            now: now
        )

        XCTAssertEqual(refined.state.playbackStatus, .playing)
        XCTAssertEqual(refined.state.track?.id, "track-1")
        XCTAssertEqual(refined.state.elapsedTime, 82.5, accuracy: 0.001)
    }

    private static func track(id: String) -> NowPlayingTrack {
        NowPlayingTrack(
            id: id,
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Apple Music"
        )
    }
}
