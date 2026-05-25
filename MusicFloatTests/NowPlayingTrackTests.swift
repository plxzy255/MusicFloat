import XCTest
@testable import MusicFloat

final class NowPlayingTrackTests: XCTestCase {
    func testTelemetryIDDoesNotExposeRawFallbackTrackIdentity() {
        let rawID = "artist|album|song title"

        let telemetryID = NowPlayingTrack.telemetryID(for: rawID)

        XCTAssertTrue(telemetryID.hasPrefix("track:"))
        XCTAssertFalse(telemetryID.contains(rawID))
        XCTAssertFalse(telemetryID.contains("artist"))
        XCTAssertFalse(telemetryID.contains("album"))
        XCTAssertFalse(telemetryID.contains("song"))
    }

    func testTelemetryIDIsStableWithinProcessForSameRawID() {
        let first = NowPlayingTrack.telemetryID(for: "same-track")
        let second = NowPlayingTrack.telemetryID(for: "same-track")

        XCTAssertEqual(first, second)
    }

    func testTelemetryIDUsesNoneForMissingTrack() {
        XCTAssertEqual(NowPlayingTrack.telemetryID(for: nil), "none")
        XCTAssertEqual(NowPlayingTrack.telemetryID(for: ""), "none")
    }
}
