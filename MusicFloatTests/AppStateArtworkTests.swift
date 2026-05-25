import AppKit
import XCTest
@testable import MusicFloat

final class AppStateArtworkTests: XCTestCase {
    @MainActor
    func testNowPlayingArtworkClearsWhenTrackChanges() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.artworkClears.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let firstTrack = NowPlayingTrack(
            id: "track-a",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let secondTrack = NowPlayingTrack(
            id: "track-b",
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: firstTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))
        appState.applyNowPlayingArtwork(NSImage(size: NSSize(width: 4, height: 4)), forTrackID: firstTrack.id)

        XCTAssertNotNil(appState.nowPlayingArtwork)
        XCTAssertEqual(appState.nowPlayingArtworkTrackID, firstTrack.id)

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: secondTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))

        XCTAssertNil(appState.nowPlayingArtwork)
        XCTAssertEqual(appState.nowPlayingArtworkTrackID, secondTrack.id)
    }

    @MainActor
    func testStaleNowPlayingArtworkIsIgnored() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.artworkStale.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let firstTrack = NowPlayingTrack(
            id: "track-a",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let secondTrack = NowPlayingTrack(
            id: "track-b",
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: firstTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))
        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: secondTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))

        appState.applyNowPlayingArtwork(NSImage(size: NSSize(width: 4, height: 4)), forTrackID: firstTrack.id)

        XCTAssertNil(appState.nowPlayingArtwork)
        XCTAssertEqual(appState.nowPlayingArtworkTrackID, secondTrack.id)
    }
}
